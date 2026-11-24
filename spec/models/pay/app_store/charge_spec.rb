RSpec.describe Pay::AppStore::Charge do
  let(:user) { User.create!(email: "ada@example.com") }
  let(:account_id) { Pay::GooglePlay::Customer.for(user).processor_id }

  def sync(**transaction)
    Pay::AppStore::Subscription.sync(app_store_transaction(account_id: account_id, price: "14.99", currency: "EUR", **transaction))
  end

  it "records the first purchase and each renewal once, at what the customer paid" do
    purchased_at = 1.month.ago
    sync(purchased_at: purchased_at, expires_at: 1.second.ago)
    sync(purchased_at: purchased_at, expires_at: 1.second.ago)
    subscription = sync(transaction_id: "2000000000000002", purchased_at: 1.second.ago, price: "9.99")

    expect(described_class.order(:created_at).map { |charge| [ charge.processor_id, charge.amount, charge.currency ] })
      .to eq([ [ "2000000000000001", 1499, "eur" ], [ "2000000000000002", 999, "eur" ] ])
    expect(described_class.first).to have_attributes(subscription: subscription, customer: Pay::AppStore::Customer.for(user), amount_refunded: 0,
                                                     created_at: be_within(1.second).of(purchased_at), product_id: "premium.monthly", sandbox?: false)
    expect(user.reload.pay_customers.find_by(processor: "app_store").charges.count).to eq(2)
  end

  it "keeps the currency's own decimals" do
    sync(price: "1500", currency: "JPY")

    expect(described_class.sole).to have_attributes(amount: 1500, currency: "jpy")
  end

  it "records nothing for a free trial, a transaction without a price or a family-shared one" do
    sync(price: "0")
    sync(transaction_id: "2", price: nil, currency: nil)
    Pay::AppStore::Subscription.sync(app_store_transaction(account_id: account_id, transaction_id: "3", price: "14.99", currency: "EUR")
                                       .merge("inAppOwnershipType" => "FAMILY_SHARED"))

    expect(described_class.count).to eq(0)
  end

  it "records a refund, full or prorated, of an older transaction too, and its reversal" do
    sync(purchased_at: 1.month.ago)
    sync(transaction_id: "2000000000000002", purchased_at: 1.second.ago)
    first = described_class.find_by!(processor_id: "2000000000000001")

    sync(purchased_at: 1.month.ago, revoked_at: Time.current)
    expect(first.reload).to have_attributes(amount_refunded: 1499, full_refund?: true)

    Pay::AppStore::Subscription.sync(app_store_transaction(account_id: account_id, purchased_at: 1.month.ago, revoked_at: Time.current, price: "14.99", currency: "EUR")
                                       .merge("revocationType" => "REFUND_PRORATED", "revocationPercentage" => 40_000))
    expect(first.reload).to have_attributes(amount_refunded: 600, partial_refund?: true)

    sync(purchased_at: 1.month.ago)
    expect(first.reload.amount_refunded).to eq(0)
  end

  it "tells sandbox and Xcode purchases apart, so revenue reports can leave them out" do
    sync(environment: "Sandbox")
    sync(transaction_id: "2", original_transaction_id: "2", environment: "Xcode")

    expect(described_class.all.map(&:sandbox?)).to eq([ true, true ])
  end

  it "never lets a payload signed before the last one undo a refund" do
    refund = app_store_transaction(account_id: account_id, revoked_at: Time.current, price: "14.99", currency: "EUR")
    stale = app_store_transaction(account_id: account_id, price: "14.99", currency: "EUR").merge("signedDate" => apple_time(1.hour.ago))
    Pay::AppStore::Subscription.sync(refund)
    Pay::AppStore::Subscription.sync(stale)

    expect(described_class.sole.amount_refunded).to eq(1499)
  end

  it "counts no refund for a Family Sharing revocation or an upgrade" do
    sync
    Pay::AppStore::Subscription.sync(app_store_transaction(account_id: account_id, revoked_at: Time.current, price: "14.99", currency: "EUR")
                                       .merge("revocationType" => "FAMILY_REVOKE"))
    expect(described_class.sole.amount_refunded).to eq(0)

    Pay::AppStore::Subscription.sync(app_store_transaction(account_id: account_id, revoked_at: Time.current, price: "14.99", currency: "EUR")
                                       .merge("isUpgraded" => true, "signedDate" => apple_time(1.second.from_now)))
    expect(described_class.sole.amount_refunded).to eq(0)
  end

  it "records nothing for another customer's transaction on the same original transaction" do
    subscription = sync
    other = User.create!(email: "grace@example.com")
    transaction = app_store_transaction(account_id: Pay::GooglePlay::Customer.for(other).processor_id, transaction_id: "5", price: "14.99", currency: "EUR")

    expect(described_class.sync(transaction, subscription)).to be_nil
    expect(described_class.count).to eq(1)
  end

  it "warns about a currency Pay does not know instead of guessing its decimals" do
    allow(Rails.logger).to receive(:warn)
    sync(currency: "XXX")

    expect(described_class.count).to eq(0)
    expect(Rails.logger).to have_received(:warn).with(/no price in a known currency/)
  end

  it "selects sandbox charges in SQL and cannot be re-read from Apple by id" do
    sync(environment: "Sandbox")
    sync(transaction_id: "2", original_transaction_id: "2")

    expect(described_class.sandbox.pluck(:processor_id)).to eq([ "2000000000000001" ])
    expect(described_class.where.not(id: described_class.sandbox).pluck(:processor_id)).to eq([ "2" ])
    expect { described_class.first.sync! }.to raise_error(Tillbell::Error, /backfill_charges/)
  end
end
