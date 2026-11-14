module Tillbell
  # Builds store subscriptions in a host app's tests, without Apple's signature or a call to
  # Google: what the stores send is built here, then saved by the same code as a real purchase.
  #
  #   # spec/rails_helper.rb
  #   require "tillbell/test_helpers"
  #   RSpec.configure { |config| config.include Tillbell::TestHelpers }
  #
  #   create_app_store_subscription(user, product_id: "app.family.monthly")
  #   create_google_play_subscription(user, state: "SUBSCRIPTION_STATE_ON_HOLD")
  #
  # Not loaded by +require "tillbell"+: test code only.
  module TestHelpers
    # Records an App Store subscription of +owner+ from +app_store_transaction+ (whose options
    # it takes) and, when given, +renewal_info+ (see +app_store_renewal_info+). Returns the
    # Pay::AppStore::Subscription, and emits the Tillbell events a real purchase would.
    def create_app_store_subscription(owner, renewal_info: nil, **transaction)
      Pay::AppStore::Subscription.sync(app_store_transaction(account_id: tillbell_account_id(owner), **transaction), renewal_info)
    end

    # Records a Google Play subscription of +owner+ under +purchase_token+ from
    # +google_subscription+ (whose options it takes). Returns the Pay::GooglePlay::Subscription,
    # and emits the Tillbell events a real purchase would.
    def create_google_play_subscription(owner, purchase_token: SecureRandom.hex(16), **response)
      Pay::GooglePlay::Subscription.sync(purchase_token, object: google_subscription(account_id: tillbell_account_id(owner), **response))
    end

    # The account id the paywall sends for +owner+: Google Play's +obfuscatedAccountId+ and
    # the App Store's +appAccountToken+.
    def tillbell_account_id(owner)
      Pay::GooglePlay::Customer.for(owner).processor_id
    end

    # A decoded App Store transaction (JWSTransaction) of an auto-renewable subscription, with
    # Apple's keys. +environment+ is "Production", "Sandbox" or "Xcode".
    def app_store_transaction(account_id:, product_id: "premium.monthly", original_transaction_id: "2000000000000001",
                              transaction_id: original_transaction_id, purchased_at: Time.current, expires_at: 1.month.from_now,
                              revoked_at: nil, environment: "Production", price: nil, currency: nil,
                              bundle_id: Tillbell.apple.bundle_id, type: Tillbell::AppStore::AUTO_RENEWABLE)
      {
        "transactionId" => transaction_id, "originalTransactionId" => original_transaction_id, "bundleId" => bundle_id,
        "productId" => product_id, "type" => type, "appAccountToken" => account_id, "environment" => environment,
        "purchaseDate" => apple_time(purchased_at), "expiresDate" => apple_time(expires_at),
        "revocationDate" => apple_time(revoked_at), "signedDate" => apple_time(Time.current),
        "price" => price && (BigDecimal(price.to_s) * 1000).to_i, "currency" => currency
      }.compact
    end

    # A decoded App Store renewal information (JWSRenewalInfo), as notifications carry it.
    def app_store_renewal_info(product_id: "premium.monthly", auto_renew: true, billing_retry: false, grace_period_ends_at: nil)
      {
        "autoRenewProductId" => product_id, "autoRenewStatus" => auto_renew ? 1 : 0, "isInBillingRetryPeriod" => billing_retry,
        "gracePeriodExpiresDate" => apple_time(grace_period_ends_at), "signedDate" => apple_time(Time.current)
      }.compact
    end

    # A Google Play Developer API +purchases.subscriptionsv2.get+ response, in the shape
    # Tillbell::GooglePlay.subscription returns (snake_case symbol keys). +test_purchase+ makes
    # it a license tester's purchase.
    def google_subscription(account_id:, state: "SUBSCRIPTION_STATE_ACTIVE", product_id: "premium", base_plan_id: "monthly",
                            expiry_time: 1.month.from_now, auto_renewing: true, acknowledged: true, linked_purchase_token: nil,
                            recurring_price: nil, deferred_product_id: nil, line_items: nil, test_purchase: false)
      {
        subscription_state: state,
        acknowledgement_state: acknowledged ? "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" : "ACKNOWLEDGEMENT_STATE_PENDING",
        external_account_identifiers: { obfuscated_external_account_id: account_id },
        linked_purchase_token: linked_purchase_token,
        test_purchase: ({} if test_purchase),
        line_items: line_items || [
          {
            product_id: product_id,
            expiry_time: expiry_time.utc.iso8601,
            offer_details: { base_plan_id: base_plan_id },
            auto_renewing_plan: { auto_renew_enabled: auto_renewing, recurring_price: recurring_price }.compact,
            deferred_item_replacement: deferred_product_id && { product_id: deferred_product_id }
          }.compact
        ]
      }.compact
    end

    # Records every Tillbell event emitted while the block runs, as +[name, payload]+ pairs.
    def tillbell_events
      events = []
      subscriber = ActiveSupport::Notifications.subscribe(/\Apay\.tillbell\./) do |name, *, payload|
        events << [ name.delete_prefix("pay.tillbell.").to_sym, payload ]
      end
      yield
      events
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # A time as Apple sends it: milliseconds since the epoch.
    def apple_time(time)
      time && (time.to_f * 1000).to_i
    end
  end
end
