module Pay
  module AppStore
    # An App Store auto-renewable subscription, stored as a Pay subscription.
    #
    # [processor_id] The +originalTransactionId+: it stays the same across renewals and plan
    #                changes within the subscription group.
    # [processor_plan] The App Store product id of the latest transaction.
    # [status] A Pay status: "active" (including the billing grace period), "past_due" (Apple
    #          retries a failed payment, without access) or "canceled" (expired or refunded).
    # [ends_at] Set once the subscription will not renew, has expired or was refunded.
    # [object] The last signed transaction payload, for debugging.
    #
    # App Store details live in +data+: +environment+ ("Production" or "Sandbox"),
    # +transaction_id+, +purchase_date_ms+, +renewal_signed_ms+, +auto_renewing+,
    # +auto_renew_product_id+, +billing_retry+, +grace_period_ends_at+ and +revoked_at+.
    class Subscription < Pay::Subscription
      store_accessor :data, :environment, :transaction_id, :purchase_date_ms, :renewal_signed_ms, :auto_renewing, :auto_renew_product_id,
        :billing_retry, :grace_period_ends_at, :revoked_at

      class << self
        # Saves a verified transaction (see Tillbell::AppStore.verify_transaction!) and, when a
        # notification brings it, its renewal information, then emits the matching Tillbell
        # events. A transaction older than the one already saved changes nothing, so restores
        # and notifications can arrive in any order.
        #
        # Returns the subscription, or nil when the transaction was not made through Tillbell
        # (no known +appAccountToken+) or was shared through Family Sharing: the family member's
        # transaction is not the buyer's purchase, and the iOS app never reports it either.
        def sync(transaction, renewal_info = nil)
          return if transaction["inAppOwnershipType"] == "FAMILY_SHARED"

          pay_customer = Pay::AppStore::Customer.for_account_id(transaction["appAccountToken"])
          if pay_customer.nil?
            Rails.logger.warn "[Tillbell] Ignoring App Store transaction #{transaction["transactionId"]}: unknown account"
            return
          end

          subscription, events = save_from_apple(pay_customer, transaction, renewal_info)
          events.each { |event| Tillbell.instrument(event, subscription) }
          subscription
        end

        private
          # Applies the transaction under a row lock, so a purchase request and a notification
          # for the same subscription serialize and only one of them emits each event.
          def save_from_apple(pay_customer, transaction, renewal_info)
            attempts = 0
            begin
              transaction(requires_new: true) do
                subscription = pay_customer.subscriptions.lock.find_or_initialize_by(processor_id: transaction["originalTransactionId"])
                subscription.apply(transaction, renewal_info)
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
      end

      # Assigns what +transaction+ and +renewal_info+ (Apple payloads) say, without saving.
      # The renewal information only comes with notifications; without it, the last known
      # renewal state is kept.
      def apply(transaction, renewal_info = nil)
        if new_record? || transaction["purchaseDate"].to_i >= purchase_date_ms.to_i
          assign_attributes(
            name: Tillbell.subscription_name.call(product_id: transaction["productId"], base_plan_id: nil),
            processor_plan: transaction["productId"],
            current_period_end: Tillbell::AppStore.time(transaction["expiresDate"]),
            object: transaction,
            environment: transaction["environment"],
            transaction_id: transaction["transactionId"],
            purchase_date_ms: transaction["purchaseDate"].to_i,
            revoked_at: Tillbell::AppStore.time(transaction["revocationDate"])&.iso8601
          )
        end
        # Renewal information is ordered by its own signing date, so a stale notification processed
        # late (a billing failure after the renewal that fixed it) never brings back old state.
        if renewal_info && renewal_info["signedDate"].to_i >= renewal_signed_ms.to_i
          assign_attributes(
            renewal_signed_ms: renewal_info["signedDate"].to_i,
            auto_renewing: renewal_info["autoRenewStatus"] == 1,
            auto_renew_product_id: renewal_info["autoRenewProductId"],
            billing_retry: renewal_info["isInBillingRetryPeriod"] == true,
            grace_period_ends_at: Tillbell::AppStore.time(renewal_info["gracePeriodExpiresDate"])&.iso8601
          )
        end
        self.auto_renewing = true if auto_renewing.nil?
        assign_status
      end

      # The Tillbell event that describes the pending changes, or nil when nothing a host app
      # cares about changed. Called before saving. Same rules as for Google Play.
      def event_for_changes
        return :subscription_created if new_record?
        return if (changed - %w[object updated_at]).none?
        return :subscription_revoked if revoked_at_changed? && revoked?
        return :subscription_expired if status_changed? && status == "canceled"
        return :subscription_canceled if ends_at_changed? && ends_at.present? && status == "active"

        :subscription_updated
      end

      # Every event the pending changes call for, the generic one first. Called before saving.
      def events_for_changes
        events = [ event_for_changes ]
        if persisted? && !revoked?
          events << :plan_changed if processor_plan_changed?
          events << :subscription_renewed if status == "active" && !processor_plan_changed? && current_period_end_changed? && current_period_end_was.present? && current_period_end > current_period_end_was
          # The store accessor's +_was+ answers nil for a value that did not change.
          was_retrying = billing_retry_changed? ? billing_retry_was : billing_retry
          events << :payment_failed if billing_retry && !was_retrying
          events << :payment_recovered if !billing_retry && was_retrying
        end
        events.compact
      end

      # True when Apple refunded the purchase.
      def revoked?
        revoked_at.present?
      end

      # True for a purchase made with a sandbox Apple Account (Xcode, TestFlight, App Review),
      # which costs nothing. Tillbell accepts them so App Review and testers can buy; check this
      # to keep them out of revenue reports, or to refuse them.
      def sandbox?
        environment == "Sandbox"
      end

      # The App Store has no base plans: each duration is its own product.
      def base_plan_id
        nil
      end

      # The plan of +Tillbell.plans+ whose +product_id+ is this App Store product, or nil.
      def plan
        Tillbell.plan(product_id: processor_plan)
      end

      # The App Store has no pause.
      def paused?
        false
      end

      # True while Apple retries a failed payment and the customer keeps access.
      def in_grace_period?
        billing_retry && status == "active"
      end

      # True when the payment failed after the grace period and access is suspended.
      def on_hold?
        status == "past_due"
      end

      # True while the App Store still counts the subscription as the customer's: buying it
      # again would be answered "already subscribed".
      def owned?
        !revoked? && (status == "active" || status == "past_due")
      end

      # The product the customer moves to at the next renewal (a downgrade within the
      # subscription group), or nil.
      def deferred_product_id
        auto_renew_product_id if auto_renew_product_id.present? && auto_renew_product_id != processor_plan
      end

      # True while a plan change waits for the next renewal. See +deferred_product_id+.
      def plan_change_pending?
        deferred_product_id.present?
      end

      # The App Store page where the customer manages their subscriptions.
      def manage_url
        Tillbell::AppStore::MANAGE_URL
      end

      # A stable identifier of the subscription that is safe to send to a third party.
      def token_digest
        Digest::SHA256.hexdigest(processor_id).first(16)
      end

      # Only the customer can stop an App Store subscription, in the App Store: Apple offers no
      # server API for it. This leaves the subscription unchanged instead of raising, so
      # deleting an owner (Pay calls +cancel_now!+) never fails on it. Tell the customer to
      # cancel it in the App Store (+manage_url+) before deleting their account.
      def cancel(**)
        Rails.logger.warn "[Tillbell] App Store subscription #{token_digest} can only be canceled by the customer, in the App Store"
        self
      end

      def cancel_now!(**)
        cancel
      end

      %i[swap pause resume change_quantity].each do |method_name|
        define_method(method_name) do |*, **|
          raise Tillbell::Error, "App Store subscriptions cannot #{method_name} from the server; use the app or the App Store"
        end
      end

      private
        # Pay status from what Apple last said, at the time of the sync. Apple notifies every
        # change (renewal, expiry, billing retry, refund), so the status stays current as long
        # as App Store Server Notifications reach the app.
        def assign_status
          expires_at = current_period_end
          grace_ends_at = grace_period_ends_at.present? ? Time.zone.parse(grace_period_ends_at) : nil

          self.status, self.ends_at =
            if revoked?
              [ "canceled", Time.zone.parse(revoked_at) ]
            elsif expires_at.nil? || expires_at.future?
              [ "active", (expires_at unless auto_renewing) ]
            elsif billing_retry && grace_ends_at&.future?
              [ "active", nil ]
            elsif billing_retry
              [ "past_due", nil ]
            else
              [ "canceled", expires_at ]
            end
        end
    end
  end
end
