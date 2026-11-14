module Tillbell
  # Subscription helpers for the model that declares +pay_customer+ (usually +User+), for an
  # owner who may have subscriptions with several Pay processors (Stripe on the web, Google
  # Play in the app).
  #
  #   class User < ApplicationRecord
  #     pay_customer
  #     include Tillbell::Owner
  #   end
  module Owner
    # The Google Play subscription of the owner, or nil. Pay's +payment_processor+ is the owner's
    # default processor, which a Google Play customer never is (see the README).
    def google_play_subscription
      customer = pay_customers.active.find_by(processor: "google_play")
      # Not Pay::Customer#subscription, which only looks at the default subscription name.
      subscriptions = customer&.subscriptions&.order(created_at: :desc)
      subscriptions&.active_or_paused&.first || subscriptions&.first
    end

    # True when the Google Play subscription is on hold: the payment failed after the grace
    # period and Google requires access to be suspended while it retries. The customer fixes it
    # in the Play Store (+manage_url+); subscribing again elsewhere would bill twice if the
    # retry succeeds.
    def google_play_on_hold?
      google_play_subscription&.on_hold? || false
    end

    # The most relevant subscription bought in an app store (Google Play or the App Store), or
    # nil: the most recent one that is active or paused, otherwise the most recent one.
    def store_subscription
      subscriptions = store_subscriptions
      subscriptions.active_or_paused.first || subscriptions.first
    end

    # True when the store subscription (see +store_subscription+) is on hold: the payment failed
    # after the store's grace period and access is suspended while the store retries. The
    # customer fixes it in the store (+manage_url+); subscribing again elsewhere would bill
    # twice if the retry succeeds.
    def store_on_hold?
      store_subscription&.on_hold? || false
    end

    # The most recent store subscription the store still counts as the customer's, with or
    # without access (see +owned?+), or nil. Buying it again would be refused by the store, and
    # buying another way (a web checkout) would bill twice: send the customer to its
    # +manage_url+ instead.
    def owned_store_subscription
      store_subscriptions.find(&:owned?)
    end

    # The App Store subscriptions that will still renew: only the customer can stop them, in
    # the App Store, so +cancel_billing_subscriptions!+ leaves them unchanged. Show their
    # +manage_url+ before closing the account.
    def subscriptions_to_cancel_in_store
      billing_subscriptions.select { |subscription| subscription.app_store? && subscription.ends_at.nil? }
    end

    # The subscription to show and to decide access from, whatever its processor: the one
    # that renews, then one that is canceled but still running, then one whose payment is
    # being retried or that is paused; the most recent breaks a tie. Nil without any.
    def current_subscription
      pay_subscriptions.includes(:customer).min_by { |subscription| [ subscription_standing(subscription), -subscription.created_at.to_i ] }
    end

    # The subscriptions that still bill the owner, or will resume by themselves (see
    # +Pay::Subscription#billing?+), Google Play first: its cancellation can be undone in the
    # Play Store and Stripe's cannot, so a Google failure must not leave a customer who
    # already lost the other one.
    def billing_subscriptions
      pay_subscriptions.includes(:customer).select(&:billing?).sort_by { |subscription| subscription.google_play? ? 0 : 1 }
    end

    # Cancels what +billing_subscriptions+ lists, to call before closing or deleting the
    # account and before changing anything in the database: an error raised afterwards would
    # leave a closed account that is still billed. Google Play subscriptions only stop
    # renewing, the customer keeps access until the end of the paid period. App Store
    # subscriptions cannot be stopped from a server: they are left unchanged, so send the
    # customer to their +manage_url+ before closing the account. Raises +Pay::Error+
    # (+Tillbell::Error+ for Google Play) when a processor refuses.
    def cancel_billing_subscriptions!
      billing_subscriptions.each(&:cancel_now!)
    end

    private
      # Subscriptions of the owner's store customers, the most recent first.
      def store_subscriptions
        pay_subscriptions.merge(Pay::Customer.active).where(pay_customers: { processor: %w[google_play app_store] }).order(created_at: :desc)
      end

      # An App Store subscription that went stale (see Pay::AppStore::Subscription#stale?) is
      # still "active" but must not hide one that grants access.
      def subscription_standing(subscription)
        active = subscription.active? && !subscription.try(:stale?)
        if active && !subscription.on_grace_period? then 0
        elsif active then 1
        elsif subscription.billing? && !subscription.try(:stale?) then 2
        else 3
        end
      end
  end
end
