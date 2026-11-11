# Builders for Google Play Developer API responses, in the shape returned by
# Tillbell::GooglePlay.subscription (snake_case symbol keys).
module GooglePlayHelpers
  # A +purchases.subscriptionsv2.get+ response.
  def google_subscription(account_id:, state: "SUBSCRIPTION_STATE_ACTIVE", product_id: "premium", base_plan_id: "monthly",
                          expiry_time: 1.month.from_now, auto_renewing: true, acknowledged: true, linked_purchase_token: nil,
                          recurring_price: nil, deferred_product_id: nil, line_items: nil)
    {
      subscription_state: state,
      acknowledgement_state: acknowledged ? "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED" : "ACKNOWLEDGEMENT_STATE_PENDING",
      external_account_identifiers: { obfuscated_external_account_id: account_id },
      linked_purchase_token: linked_purchase_token,
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

  # Makes Google answer +response+ for +purchase_token+.
  def stub_google_subscription(purchase_token, response)
    allow(Tillbell::GooglePlay).to receive(:subscription).with(purchase_token).and_return(response)
  end

  # Records every Tillbell event emitted while the block runs, as [name, payload] pairs.
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

  # A Google API error as raised by the google-apis gems.
  def google_error(klass, status)
    klass.new("Google error", status_code: status)
  end
end

RSpec.configure { |config| config.include GooglePlayHelpers }
