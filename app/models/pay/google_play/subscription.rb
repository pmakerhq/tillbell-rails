module Pay
  module GooglePlay
    # A Google Play subscription, stored as a Pay subscription.
    #
    # Columns hold the same meaning as for any other Pay processor:
    #
    # [processor_id] The Google purchase token.
    # [processor_plan] The Google product id (the subscription id in the Play Console).
    # [status] A Pay status, mapped from Google's state by STATUSES.
    # [ends_at] Set once the subscription is canceled, expired or revoked.
    # [object] The last response of the Google Play Developer API, for debugging.
    #
    # Google-specific details live in +data+: the raw +subscription_state+, the
    # +base_plan_id+, +auto_renewing+ and +revoked_at+.
    #
    # Because statuses use Pay's vocabulary, Pay helpers behave exactly as they do for
    # Stripe: +active?+, +past_due?+, +on_grace_period?+, +Pay::Subscription.active+, ...
    class Subscription < Pay::Subscription
      # Google +subscriptionState+ => Pay status.
      #
      # * In grace period, Google requires the customer to keep access, so it maps to
      #   "active". Use +in_grace_period?+ to show a "fix your payment" banner.
      # * Canceled means "will not renew": access continues until +ends_at+, which is how
      #   Pay represents a canceled subscription that is still valid.
      # * On hold means the payment failed after the grace period; access is suspended
      #   while Google retries, like a Stripe "past_due" subscription.
      #
      # See https://developer.android.com/google/play/billing/lifecycle/subscriptions
      STATUSES = {
        "SUBSCRIPTION_STATE_PENDING" => "incomplete",
        "SUBSCRIPTION_STATE_ACTIVE" => "active",
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" => "active",
        "SUBSCRIPTION_STATE_ON_HOLD" => "past_due",
        "SUBSCRIPTION_STATE_PAUSED" => "paused",
        "SUBSCRIPTION_STATE_CANCELED" => "active",
        "SUBSCRIPTION_STATE_EXPIRED" => "canceled",
        "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED" => "incomplete_expired"
      }.freeze

      # Google states after which the subscription ends at the expiry time of its period.
      ENDING_STATES = %w[SUBSCRIPTION_STATE_CANCELED SUBSCRIPTION_STATE_EXPIRED].freeze

      ACTIVE_STATE = "SUBSCRIPTION_STATE_ACTIVE".freeze

      # Google states of a payment that failed and is being retried.
      PAYMENT_PROBLEM_STATES = %w[SUBSCRIPTION_STATE_IN_GRACE_PERIOD SUBSCRIPTION_STATE_ON_HOLD].freeze

      # Google states in which the purchase still belongs to the customer (see +owned?+): every
      # state but an expiry and a pending purchase that was canceled. A whitelist, so an unknown
      # or missing state (a row older than the state column) never blocks a new purchase.
      OWNED_STATES = %w[
        SUBSCRIPTION_STATE_PENDING SUBSCRIPTION_STATE_ACTIVE SUBSCRIPTION_STATE_IN_GRACE_PERIOD
        SUBSCRIPTION_STATE_ON_HOLD SUBSCRIPTION_STATE_PAUSED SUBSCRIPTION_STATE_CANCELED
      ].freeze

      store_accessor :data, :subscription_state, :base_plan_id, :auto_renewing, :revoked_at, :replaced_by

      class << self
        # Reads a purchase from Google (unless +object+ is given), saves it and emits the
        # matching Tillbell event. Safe to call any number of times, in any order: the
        # result only depends on Google's current state, and an event fires only when
        # something changed.
        #
        # +revoked+ tells that Google refunded the purchase, which the API response alone
        # does not distinguish from a normal expiry.
        #
        # Returns the subscription, or nil when the purchase was not made through Tillbell
        # (no known +obfuscatedAccountId+).
        def sync(purchase_token, object: nil, revoked: false)
          object ||= Tillbell::GooglePlay.subscription(purchase_token)

          pay_customer = Pay::GooglePlay::Customer.find_by(processor_id: Tillbell::GooglePlay.account_id(object))
          if pay_customer.nil?
            Rails.logger.warn "[Tillbell] Ignoring Google Play purchase #{Tillbell.redact(purchase_token)}: unknown account"
            return
          end

          subscription, events = save_from_google(pay_customer, purchase_token, attributes_from(object, revoked: revoked))
          events.each { |event| Tillbell.instrument(event, subscription) }

          retire(object[:linked_purchase_token], replaced_by: purchase_token).each do |old, expired|
            Tillbell.instrument(:subscription_expired, old) if expired
            Tillbell.instrument(:plan_changed, subscription) if [ old.processor_plan, old.base_plan_id ] != [ subscription.processor_plan, subscription.base_plan_id ]
          end
          acknowledge(subscription, object)
          subscription
        end

        # Maps a +subscriptionsv2+ response to subscription attributes. Pure function, no I/O.
        def attributes_from(object, revoked: false)
          state = object[:subscription_state]
          line_item = object[:line_items].max_by { |item| item[:expiry_time].to_s }
          product_id = line_item[:product_id]
          base_plan_id = line_item.dig(:offer_details, :base_plan_id)
          expires_at = line_item[:expiry_time]&.then { |time| Time.zone.parse(time) }

          attributes = {
            name: Tillbell.subscription_name.call(product_id: product_id, base_plan_id: base_plan_id),
            processor_plan: product_id,
            status: STATUSES.fetch(state) { raise Tillbell::Error, "Unknown Google Play subscription state #{state.inspect}" },
            current_period_end: expires_at,
            ends_at: (expires_at if ENDING_STATES.include?(state)),
            object: object,
            subscription_state: state,
            base_plan_id: base_plan_id,
            auto_renewing: line_item.dig(:auto_renewing_plan, :auto_renew_enabled) || false
          }
          attributes.merge!(status: "canceled", ends_at: Time.current, revoked_at: Time.current.iso8601) if revoked
          attributes
        end

        private
          # Saves the attributes under a row lock and returns the subscription with the
          # events its changes call for. Concurrent syncs of the same token (purchase
          # request and notification) serialize on the lock, so only one emits the event.
          def save_from_google(pay_customer, purchase_token, attributes)
            attempts = 0
            begin
              # A savepoint, so a failed insert never breaks a transaction the caller opened.
              transaction(requires_new: true) do
                subscription = pay_customer.subscriptions.lock.find_or_initialize_by(processor_id: purchase_token)
                # A refund is final: later reads report a normal expiry (or, if Google is
                # lagging, an active subscription), and a duplicated refund notification
                # must not emit a second event. So is a replacement: the new purchase carries
                # the access, and a later read of the old token (a deferred plan change may
                # still report it as active until the renewal) must not bring it back.
                subscription.assign_attributes(subscription.revoked? || subscription.replaced? ? attributes.except(:status, :ends_at, :revoked_at) : attributes)

                events = subscription.events_for_changes
                subscription.save!
                [ subscription, events ]
              end
            rescue ActiveRecord::RecordNotUnique
              # Another process inserted the row first; a second attempt finds it and locks it.
              attempts += 1
              attempts == 1 ? retry : raise
            end
          end

          # A purchase that replaces another (a plan change, or a customer who signs up again
          # for a canceled subscription) gets a new purchase token that points to the old one.
          # The old subscription ends now, remembers the token that replaced it, and the new
          # one carries the access.
          #
          # Returns +[subscription, expired]+ pairs for the subscriptions it marked as replaced,
          # +expired+ telling whether this call ended them: a notification about the old token
          # may have ended it first (and emitted +subscription_expired+, before the replacement
          # was known). Rows are locked and skipped once replaced, so two syncs of the same new
          # token (purchase request and notification) retire the old one, and report it, once.
          def retire(linked_purchase_token, replaced_by:)
            return [] if linked_purchase_token.blank?

            transaction(requires_new: true) do
              where(processor_id: linked_purchase_token).lock.reject(&:replaced?).map do |subscription|
                expired = subscription.status != "canceled"
                subscription.update!(status: "canceled", ends_at: expired ? Time.current : subscription.ends_at, replaced_by: replaced_by)
                [ subscription, expired ]
              end
            end
          end

          # Acknowledges the purchase once it grants access. The native app never does it.
          def acknowledge(subscription, object)
            return unless object[:acknowledgement_state] == "ACKNOWLEDGEMENT_STATE_PENDING" && subscription.active?

            Tillbell::GooglePlay.acknowledge(subscription.processor_plan, subscription.processor_id)
          end
      end

      # The Tillbell event that describes the pending changes, or nil when nothing a host
      # app cares about changed. Called before saving.
      def event_for_changes
        return :subscription_created if new_record?
        return if (changed - %w[object updated_at]).none?
        return :subscription_revoked if revoked_at_changed?
        return :subscription_expired if status_changed? && status == "canceled"
        return :subscription_canceled if ends_at_changed? && ends_at.present? && status == "active"

        :subscription_updated
      end

      # Every event the pending changes call for, the generic one first (see
      # +event_for_changes+) then the detailed ones the host app would otherwise have to
      # deduce from +saved_changes+. Called before saving.
      def events_for_changes
        events = [ event_for_changes ]
        events.push(*detail_events) if persisted? && !revoked? && !replaced?
        events.compact
      end

      # True while Google retries a failed payment and the customer keeps access.
      def in_grace_period?
        subscription_state == "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
      end

      # True when the payment failed after the grace period and access is suspended.
      def on_hold?
        subscription_state == "SUBSCRIPTION_STATE_ON_HOLD"
      end

      # True when Google refunded the purchase.
      def revoked?
        revoked_at.present?
      end

      def paused?
        status == "paused"
      end

      # True for a purchase made by a license tester, which Google does not charge: Google's
      # answer then carries +testPurchase+. Check it to keep test purchases out of revenue
      # reports and conversion events.
      def sandbox?
        google_object.key?(:test_purchase)
      end

      # True while Google still counts the purchase as the customer's: buying the same product
      # again would be answered +ALREADY_OWNED+, so offer +manage_url+ rather than a paywall. It
      # covers states that give no access (see +grants_access?+): a paused subscription resumes
      # by itself and a pending purchase (a cash payment) completes or lapses at Google. A
      # refunded, replaced or expired purchase is no longer owned, whatever Google still reports
      # for its token.
      def owned?
        !revoked? && !replaced? && OWNED_STATES.include?(subscription_state)
      end

      # The Play Store page where the customer manages this subscription (update the payment
      # method, cancel, resubscribe). See Tillbell::GooglePlay.manage_url.
      def manage_url
        Tillbell::GooglePlay.manage_url(processor_plan)
      end

      # Price of one renewal in the units of its currency (a +BigDecimal+: 12.99 euros, 1200
      # yen), as Google bills it in the customer's country, or nil when Google's answer has
      # none. Meant for analytics and conversion events; show prices to customers from Google
      # Play (the paywall does), which knows taxes and promotions. It is the price of the
      # entitlement in force, so a subscription with add-ons reports the base item only.
      def price_amount
        price = recurring_price
        return unless price

        BigDecimal(price[:units].to_i) + (BigDecimal(price[:nanos].to_i) / 1_000_000_000)
      end

      # ISO 4217 code of the currency of +price_amount+ ("EUR"), or nil.
      def price_currency
        recurring_price&.dig(:currency_code)
      end

      # The purchase token of the subscription this purchase replaces. Google sets it when a
      # purchase replaces another: a plan change (upgrade, downgrade, other billing period), a
      # customer who signs up again for a subscription that was canceled but had not lapsed,
      # and a prepaid plan converted to or topped up as an auto-renewing one.
      def linked_purchase_token
        google_object[:linked_purchase_token].presence
      end

      # True when this purchase replaces an earlier one: see +linked_purchase_token+ for the
      # cases. Compare +processor_plan+ with the replaced subscription's to tell a plan change
      # from a customer who signed up again for the same product.
      def replacement?
        linked_purchase_token.present?
      end

      # True when a newer purchase replaced this subscription (see +replacement?+). Tillbell
      # ends a replaced subscription on its own and emits +subscription_expired+: check this to
      # tell it from a customer who left. Set when the replacement is recorded, so it is
      # already true inside the +subscription_expired+ callback; subscriptions replaced before
      # this was added are not flagged.
      def replaced?
        replaced_by.present?
      end

      # The product the customer will move to at the next renewal, when a plan change was
      # asked with the +DEFERRED+ replacement mode (the usual choice for a downgrade), or
      # nil. Google reports it on the NEW purchase, in the line item of the entitlement that
      # is about to end; until the renewal +processor_plan+ stays the current product.
      def deferred_product_id
        google_object[:line_items].to_a.filter_map { |item| item.dig(:deferred_item_replacement, :product_id).presence }.first
      end

      # True while a plan change waits for the next renewal. See +deferred_product_id+.
      def plan_change_pending?
        deferred_product_id.present?
      end

      # The subscription this purchase replaces (see +replacement?+), or nil.
      def replaced_subscription
        self.class.find_by(processor_id: linked_purchase_token) if replacement?
      end

      # The plan of +Tillbell.plans+ this subscription is on, or nil when it is not in the
      # catalog.
      def plan
        Tillbell.plan(product_id: processor_plan, base_plan_id: base_plan_id)
      end

      # A stable identifier of the purchase that is safe to send to a third party (an analytics
      # or advertising event id): the purchase token itself grants access to the subscription
      # and must never leave the server.
      def token_digest
        Digest::SHA256.hexdigest(processor_id).first(16)
      end

      # Stops the renewal with Google; access continues until the end of the period.
      # A subscription that already stopped renewing (or ended) has nothing to stop: it is only
      # refreshed, or left alone. Deleting an owner (Pay calls +cancel_now!+ on every
      # subscription still granting access) must not fail on it.
      #
      # Google answers 410 for a purchase token that expired more than 60 days ago. A
      # subscription still stored as active (a missed notification) then has nothing left to
      # stop: it is recorded as ended, instead of failing the deletion of its owner. Any other
      # error (a 404 or 400 from a wrong package name, a 403, a revoked service account key) is
      # raised as a +Tillbell::Error+ (a +Pay::Error+), whose +cause+ is Google's error: the
      # subscription may still be billing, and the host app only has to rescue Pay's error.
      def cancel(**)
        return self if ended?

        Tillbell::GooglePlay.cancel(processor_plan, processor_id) unless renewal_stopped?
        sync!
      rescue *Tillbell::GooglePlay::API_ERRORS => error
        raise Tillbell::Error, "Google Play refused to stop the renewal: #{error.message}" unless error.try(:status_code) == 410

        update!(status: "canceled", ends_at: [ current_period_end, Time.current ].compact.min, auto_renewing: false)
        Tillbell.instrument(:subscription_expired, self)
        self
      end

      # Google can only end a subscription immediately by refunding it, which Tillbell
      # never does on its own. This stops the renewal instead, so deleting an owner (Pay
      # calls +cancel_now!+ then) never leaves a subscription billing forever.
      def cancel_now!(**)
        cancel
      end

      # Plan changes, pauses and resumes happen in the app (plan change through the
      # paywall) or in the Play Store.
      %i[swap pause resume change_quantity].each do |method_name|
        define_method(method_name) do |*, **|
          raise Tillbell::Error, "Google Play subscriptions cannot #{method_name} from the server; use the app or the Play Store"
        end
      end

      private
        # Events that say what happened to an existing subscription, deduced from its pending
        # changes: +:plan_changed+ (the product or base plan changed on the same purchase, e.g. a
        # deferred downgrade that took effect), +:subscription_renewed+, +:payment_failed+ (the
        # first failure only: the move from the grace period to the hold is not a second one),
        # +:payment_recovered+ and +:subscription_reactivated+ (a cancellation taken back before the
        # end of the period). A replacement purchase is announced by +Subscription.sync+.
        def detail_events
          events = []
          events << :plan_changed if processor_plan_changed? || base_plan_id_changed?
          events << :subscription_reactivated if status == "active" && !status_changed? && ends_at_changed? && ends_at.nil?
          events << :subscription_renewed if renewed?
          events << :payment_failed if PAYMENT_PROBLEM_STATES.include?(subscription_state) && !PAYMENT_PROBLEM_STATES.include?(previous_state)
          events << :payment_recovered if subscription_state == ACTIVE_STATE && PAYMENT_PROBLEM_STATES.include?(previous_state)
          events
        end

        # A new period started: the expiry moved on while the subscription was in good standing
        # or recovering. Not the first activation of a pending purchase.
        def renewed?
          subscription_state == ACTIVE_STATE && current_period_end_changed? && current_period_end_was.present? &&
            [ ACTIVE_STATE, *PAYMENT_PROBLEM_STATES ].include?(previous_state)
        end

        # The state before the pending changes. The store accessor's +_was+ answers nil for a
        # state that did not change.
        def previous_state
          subscription_state_changed? ? subscription_state_was : subscription_state
        end

        # True when Google already reports the subscription as canceled or expired. The state,
        # not +auto_renewing+, which comes from the entitlement about to end and is false while a
        # deferred plan change waits for the renewal, though the subscription will renew.
        def renewal_stopped?
          ENDING_STATES.include?(subscription_state)
        end

        # Google's last answer with indifferent keys: symbols while the subscription is the
        # one just synced, strings once it is read back from the database.
        def google_object
          ActiveSupport::HashWithIndifferentAccess.new(object || {})
        end

        # The +recurring_price+ of the line item with the latest known expiry, i.e. the
        # entitlement in force (Google lists the one about to end and the one that follows during
        # a deferred plan change; the latter has no expiry yet and sorts first), as a hash with
        # +units+, +nanos+ and +currency_code+.
        def recurring_price
          item = google_object[:line_items].to_a.max_by { |line| line[:expiry_time].to_s }
          item&.dig(:auto_renewing_plan, :recurring_price)
        end
    end
  end
end
