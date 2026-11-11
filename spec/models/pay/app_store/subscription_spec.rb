RSpec.describe Pay::AppStore::Subscription do
  let(:user) { User.create!(email: "ada@example.com") }
  let(:account_id) { Pay::GooglePlay::Customer.for(user).processor_id }

  def sync(renewal_info = nil, **transaction)
    described_class.sync(app_store_transaction(account_id: account_id, **transaction), renewal_info)
  end

  it "shares the owner's account id with Google Play and ignores unknown accounts" do
    expect(Pay::AppStore::Customer.for(user).processor_id).to eq(account_id)
    expect(described_class.sync(app_store_transaction(account_id: SecureRandom.uuid))).to be_nil
  end

  it "maps Apple's state to Pay statuses" do
    expect(sync).to have_attributes(status: "active", ends_at: nil)
    expect(sync(app_store_renewal_info(auto_renew: false))).to have_attributes(status: "active", ends_at: be_present)
    expect(sync(expires_at: 1.day.ago, purchased_at: 1.second.from_now)).to have_attributes(status: "canceled", ends_at: be_within(1.second).of(1.day.ago))
  end

  it "keeps access during the billing grace period, then suspends it during the billing retry" do
    grace = sync(app_store_renewal_info(billing_retry: true, grace_period_ends_at: 3.days.from_now), expires_at: 1.hour.ago)
    expect(grace).to have_attributes(status: "active", in_grace_period?: true)
    expect(grace.grants_access?).to be(true)

    on_hold = sync(app_store_renewal_info(billing_retry: true), expires_at: 1.hour.ago)
    expect(on_hold).to have_attributes(status: "past_due", on_hold?: true)
    expect(on_hold.grants_access?).to be(false)
  end

  it "ends a refunded subscription for good and says so" do
    sync
    events = tillbell_events { sync(revoked_at: Time.current) }

    expect(described_class.sole).to have_attributes(status: "canceled", revoked?: true, grants_access?: false)
    expect(events.map(&:first)).to eq([ :subscription_revoked ])
  end

  it "ignores a transaction older than the one it has, so notifications can arrive in any order" do
    sync(product_id: "premium.yearly", purchased_at: Time.current)
    sync(product_id: "premium.monthly", purchased_at: 1.day.ago)

    expect(described_class.sole.processor_plan).to eq("premium.yearly")
  end

  it "reports an upgrade and a pending downgrade" do
    sync
    events = tillbell_events { sync(product_id: "premium.yearly", purchased_at: 1.second.from_now) }
    expect(events.map(&:first)).to eq([ :subscription_updated, :plan_changed ])

    downgrade = sync(app_store_renewal_info(product_id: "premium.monthly"), product_id: "premium.yearly", purchased_at: 1.second.from_now)
    expect(downgrade).to have_attributes(deferred_product_id: "premium.monthly", plan_change_pending?: true)
  end

  it "ignores a family-shared transaction, which is not the buyer's purchase" do
    transaction = app_store_transaction(account_id: account_id).merge("inAppOwnershipType" => "FAMILY_SHARED")

    expect(described_class.sync(transaction)).to be_nil
    expect(described_class.count).to eq(0)
  end

  it "never lets stale renewal information undo a newer one" do
    newer = app_store_renewal_info.merge("signedDate" => apple_time(Time.current))
    stale = app_store_renewal_info(billing_retry: true).merge("signedDate" => apple_time(1.hour.ago))
    sync(newer)
    sync(stale, purchased_at: 1.day.ago)

    expect(described_class.sole).to have_attributes(billing_retry: false, status: "active")
  end

  it "reports a payment failure once, not again on a repeated sync" do
    sync
    failing = app_store_renewal_info(billing_retry: true, grace_period_ends_at: 3.days.from_now)

    first = tillbell_events { sync(failing) }
    again = tillbell_events { sync(failing) }

    expect(first.map(&:first)).to include(:payment_failed)
    expect(again.map(&:first)).not_to include(:payment_failed)
  end

  it "finds its plan by App Store product id and tells sandbox purchases apart" do
    Tillbell.plans = [ { name: :monthly, product_id: "premium.monthly" } ]

    expect(sync).to have_attributes(plan: Tillbell.plan(:monthly), base_plan_id: nil, sandbox?: true)
  ensure
    Tillbell.plans = []
  end

  it "never fails to delete an owner: only the customer can cancel in the App Store" do
    subscription = sync

    expect(subscription.cancel_now!).to eq(subscription)
    expect(subscription.reload.status).to eq("active")
    expect(subscription.manage_url).to eq("https://apps.apple.com/account/subscriptions")
  end
end
