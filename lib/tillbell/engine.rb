module Tillbell
  # Mountable engine providing the purchase and notification endpoints, the paywall
  # helper and the Pay processor models.
  #
  # Mount it in the host app's routes:
  #
  #   mount Tillbell::Engine, at: "/tillbell"
  class Engine < ::Rails::Engine
    isolate_namespace Tillbell

    # Display names of the stores, by Pay processor.
    STORE_NAMES = { "google_play" => "Google Play", "app_store" => "App Store" }.freeze

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

        # True for a customer of an app store (Google Play or the App Store), whose
        # subscriptions are managed in the store rather than by the app.
        def store?
          google_play? || app_store?
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

        # True for a subscription bought in an app store (Google Play or the App Store). The
        # customer manages it in the store (+manage_url+): the server can neither change its
        # plan nor, for the App Store, stop it.
        def store?
          customer.store?
        end

        # The name of the store the subscription was bought in, "Google Play" or "App Store",
        # for admin pages and internal alerts; nil for any other processor. Brand names, so
        # they are not translated.
        def store_name
          STORE_NAMES[customer.processor]
        end

        # True when the subscription gives access and will renew by itself: +grants_access?+,
        # and not canceled with an end date still to come (Pay's +on_grace_period?+). Use it to
        # warn a customer who is about to close their account or switch plans while a renewal
        # is planned.
        def renewing?
          grants_access? && !on_grace_period?
        end

        # True for a test purchase that costs nothing. Always false here; store subscriptions
        # answer from what the store says (see Pay::AppStore::Subscription#sandbox? and
        # Pay::GooglePlay::Subscription#sandbox?).
        def sandbox?
          false
        end
      end
    end

    initializer "tillbell.helpers" do
      ActiveSupport.on_load(:action_view) { include Tillbell::PaywallHelper }
    end
  end
end
