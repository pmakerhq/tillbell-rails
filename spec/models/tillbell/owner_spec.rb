RSpec.describe Tillbell::Owner do
  let(:user) { User.create!(email: "ada@example.com") }
  let(:google_customer) { Pay::GooglePlay::Customer.for(user) }
  let(:stripe_customer) { user.pay_customers.create!(processor: "fake_processor", processor_id: "cus_1", default: true) }

  def play(status: "active", ends_at: nil, token: "token", name: "default", **attributes)
    Pay::GooglePlay::Subscription.create!(customer: google_customer, name: name, processor_id: token, processor_plan: "premium",
                                          status: status, ends_at: ends_at, **attributes)
  end

  def stripe(status: "active", **attributes)
    Pay::FakeProcessor::Subscription.create!(customer: stripe_customer, name: "default", processor_id: "sub_#{status}", processor_plan: "price_1",
                              status: status, **attributes)
  end

  describe "#google_play_subscription and #google_play_on_hold?" do
    it "finds the Google Play subscription, whatever the default processor" do
      stripe
      subscription = play

      expect(user.google_play_subscription).to eq(subscription)
      expect(user.google_play_on_hold?).to be(false)
    end

    it "is nil, and not on hold, without one" do
      expect(user.google_play_subscription).to be_nil
      expect(user.google_play_on_hold?).to be(false)
    end

    it "finds it whatever the Pay subscription name" do
      subscription = play(name: "premium")

      expect(user.google_play_subscription).to eq(subscription)
    end

    it "tells a subscription on hold" do
      play(status: "past_due", data: { subscription_state: "SUBSCRIPTION_STATE_ON_HOLD" })

      expect(user.google_play_on_hold?).to be(true)
    end
  end

  describe "#current_subscription" do
    it "is nil without a subscription" do
      expect(user.current_subscription).to be_nil
    end

    it "prefers the renewing subscription over an ended one, whatever the processor" do
      stripe(status: "canceled", ends_at: 1.day.ago)
      active = play

      expect(user.current_subscription).to eq(active)
    end

    it "prefers a renewing subscription over one that is canceled but still running, then over a retried payment" do
      stripe(status: "past_due")
      running = play(ends_at: 1.week.from_now, token: "running")
      expect(user.current_subscription).to eq(running)

      renewing = play(token: "renewing")
      expect(user.reload.current_subscription).to eq(renewing)
    end

    it "takes the most recent of two equal subscriptions" do
      play(token: "old", created_at: 2.days.ago)
      recent = play(token: "recent")

      expect(user.current_subscription).to eq(recent)
    end
  end

  describe "Pay::Subscription#grants_access?" do
    it "keeps access while Stripe retries a payment, not while Google holds it" do
      expect(stripe(status: "past_due").grants_access?).to be(true)
      expect(play(status: "past_due").grants_access?).to be(false)
    end

    it "gives no access to a paused or ended subscription" do
      expect(play(status: "paused", token: "paused").grants_access?).to be(false)
      expect(stripe(status: "canceled", ends_at: 1.day.ago).grants_access?).to be(false)
    end
  end

  describe "#billing_subscriptions and #cancel_billing_subscriptions!" do
    it "lists what still bills or resumes by itself, Google Play first" do
      stripe_active = stripe
      play(status: "canceled", ends_at: 1.day.ago, token: "ended")
      paused = play(status: "paused", token: "paused")
      on_hold = play(status: "past_due", token: "hold")

      expect(user.billing_subscriptions.first(2)).to contain_exactly(paused, on_hold)
      expect(user.billing_subscriptions.last).to eq(stripe_active)
      expect(user.billing_subscriptions.size).to eq(3)
    end

    it "includes a Stripe subscription whose pause started, which keeps the status active" do
      paused = stripe(pause_starts_at: 1.hour.ago, pause_behavior: "void")
      allow(paused).to receive(:paused?).and_return(true)
      allow_any_instance_of(Pay::FakeProcessor::Subscription).to receive(:paused?).and_return(true)

      expect(user.billing_subscriptions.map(&:id)).to eq([ paused.id ])
    end

    it "cancels each of them" do
      subscriptions = [ stripe, play ]
      cancelled = []
      [ Pay::GooglePlay::Subscription, Pay::FakeProcessor::Subscription ].each do |klass|
        allow_any_instance_of(klass).to receive(:cancel_now!) { |subscription| cancelled << subscription.id }
      end

      user.cancel_billing_subscriptions!

      expect(cancelled).to match_array(subscriptions.map(&:id))
    end
  end

  describe "store subscriptions, whatever the store" do
    let(:account_id) { google_customer.processor_id }

    def app_store(renewal_info = nil, **transaction)
      Pay::AppStore::Subscription.sync(app_store_transaction(account_id: account_id, **transaction), renewal_info)
    end

    it "finds the active one first, then the most recent one, never another processor's" do
      stripe
      expect(user.store_subscription).to be_nil

      expired = play(status: "canceled", ends_at: 1.day.ago, data: { subscription_state: "SUBSCRIPTION_STATE_EXPIRED" })
      expect(user.store_subscription).to eq(expired)

      active = app_store
      expect(user.store_subscription).to eq(active)
      expect(user.owned_store_subscription).to eq(active)
    end

    it "tells an App Store subscription on hold" do
      expect(user.store_on_hold?).to be(false)

      app_store(app_store_renewal_info(billing_retry: true), expires_at: 1.hour.ago)

      expect(user.store_on_hold?).to be(true)
      expect(user.owned_store_subscription).to be_present
    end

    it "does not let a stale App Store subscription hide one that pays" do
      Tillbell.apple.stale_after = 16.days
      paying = stripe
      stale = app_store(expires_at: 20.days.ago, purchased_at: 1.second.from_now)
      stale.update!(status: "active", ends_at: nil)

      expect(user.current_subscription).to eq(paying)
    ensure
      Tillbell.apple.stale_after = nil
    end

    it "lists the App Store subscriptions only the customer can stop" do
      play
      renewing = app_store

      expect(user.subscriptions_to_cancel_in_store).to eq([ renewing ])

      app_store(app_store_renewal_info(auto_renew: false))
      expect(user.subscriptions_to_cancel_in_store).to be_empty
    end
  end
end
