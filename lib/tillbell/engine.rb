module Tillbell
  # Mountable engine providing the purchase and notification endpoints, the paywall
  # helper and the Pay processor models.
  #
  # Mount it in the host app's routes:
  #
  #   mount Tillbell::Engine, at: "/tillbell"
  class Engine < ::Rails::Engine
    isolate_namespace Tillbell

    # Real-time developer notifications are verified, stored and queued by Pay (see
    # Tillbell::NotificationsController). Once Pay's job processes one, Tillbell re-reads
    # the subscription from Google.
    initializer "tillbell.notifications" do
      Pay::Webhooks.delegator.subscribe "google_play", ->(event) { Tillbell::GooglePlay.handle_notification(event) }
      Pay::Webhooks.delegator.subscribe "app_store", ->(event) { Tillbell::AppStore.handle_notification(event) }
    end

    # Pay defines +stripe?+, +paddle_billing?+ and the matching scopes for its own
    # processors only; this adds the same pair for Google Play and the App Store.
    initializer "tillbell.processor_helpers" do
      ActiveSupport.on_load(:pay_customer) do
        scope :google_play, -> { where(processor: "google_play") }
        scope :app_store, -> { where(processor: "app_store") }

        def google_play?
          processor == "google_play"
        end

        def app_store?
          processor == "app_store"
        end
      end

      ActiveSupport.on_load(:pay_subscription) do
        # True while the processor still bills the subscription, or will resume it by itself:
        # active (including a canceled one that has not ended), retried after a failed payment
        # (past_due, unpaid) or paused (a Stripe pause keeps the status "active" and resumes by
        # itself). These are the ones to cancel before closing an account. A Google Play purchase
        # still pending (cash payments) is not: Google cannot cancel it until it completes.
        def billing?
          !ended? && (active? || past_due? || unpaid? || paused?)
        end

        # True when the subscription should give access to what it pays for: it bills
        # (+billing?+) and is not paused. A payment the processor retries keeps access, so the
        # customer can still reach the page where they fix it, except on the stores: a Google Play
        # subscription on hold, or an App Store one in billing retry, is past_due after the
        # store's grace period, and the store requires access to be suspended until the payment
        # succeeds. Combine it with
        # +Tillbell::Owner#current_subscription+ to decide what an owner may use.
        def grants_access?
          billing? && !paused? && !((google_play? || app_store?) && past_due?)
        end

        scope :google_play, -> { joins(:customer).where(pay_customers: { processor: "google_play" }) }
        scope :app_store, -> { joins(:customer).where(pay_customers: { processor: "app_store" }) }

        # True for a subscription bought with Google Play, whatever the owner's default
        # processor is.
        def google_play?
          customer.processor == "google_play"
        end

        # True for a subscription bought with the App Store.
        def app_store?
          customer.processor == "app_store"
        end
      end
    end

    initializer "tillbell.helpers" do
      ActiveSupport.on_load(:action_view) { include Tillbell::PaywallHelper }
    end
  end
end
