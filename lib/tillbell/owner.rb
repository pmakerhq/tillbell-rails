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
    # renewing, the customer keeps access until the end of the paid period. Raises +Pay::Error+
    # (+Tillbell::Error+ for Google Play) when a processor refuses.
    def cancel_billing_subscriptions!
      billing_subscriptions.each(&:cancel_now!)
    end

    private
      def subscription_standing(subscription)
        if subscription.active? && !subscription.on_grace_period? then 0
        elsif subscription.active? then 1
        elsif subscription.billing? then 2
        else 3
        end
      end
  end
end
