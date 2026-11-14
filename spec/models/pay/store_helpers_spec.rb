# Helpers Tillbell adds to every Pay subscription, so code can treat both stores alike.
RSpec.describe "Store helpers on Pay subscriptions" do
  let(:user) { User.create!(email: "ada@example.com") }
  let(:account_id) { Pay::GooglePlay::Customer.for(user).processor_id }
  let(:stripe_customer) { user.pay_customers.create!(processor: "fake_processor", processor_id: "cus_1", default: true) }

  def play(**options)
    Pay::GooglePlay::Subscription.sync("token", object: google_subscription(account_id: account_id, **options))
  end

  def app_store(renewal_info = nil, **transaction)
    Pay::AppStore::Subscription.sync(app_store_transaction(account_id: account_id, **transaction), renewal_info)
  end

  def stripe(**attributes)
    Pay::FakeProcessor::Subscription.create!(customer: stripe_customer, name: "default", processor_id: "sub_1", processor_plan: "price_1",
                                            status: "active", **attributes)
  end

  it "tells store subscriptions and names their store" do
    expect([ play, app_store, stripe ].map { |subscription| [ subscription.store?, subscription.store_name ] })
      .to eq([ [ true, "Google Play" ], [ true, "App Store" ], [ false, nil ] ])
    expect(stripe_customer.store?).to be(false)
    expect(Pay::AppStore::Customer.for(user).store?).to be(true)
  end

  it "is renewing while it gives access and has no end date" do
    expect(app_store).to be_renewing
    expect(app_store(app_store_renewal_info(auto_renew: false))).not_to be_renewing
    expect(stripe(ends_at: 1.week.from_now)).not_to be_renewing
  end

  it "tells test purchases" do
    expect(play).not_to be_sandbox
    expect(Pay::GooglePlay::Subscription.sync("test", object: google_subscription(account_id: account_id, test_purchase: true))).to be_sandbox
    expect(app_store).not_to be_sandbox
    expect(app_store(environment: "Sandbox")).to be_sandbox
    expect(stripe).not_to be_sandbox
  end

  it "answers the replacement questions on the App Store too" do
    expect(app_store).to have_attributes(replacement?: false, replaced?: false)
  end
end
