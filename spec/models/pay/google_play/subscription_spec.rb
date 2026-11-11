RSpec.describe Pay::GooglePlay::Subscription do
  let(:user) { User.create!(email: "ada@example.com") }
  let(:account_id) { Pay::GooglePlay::Customer.for(user).processor_id }
  let(:token) { "purchase-token" }

  before { allow(Tillbell::GooglePlay).to receive(:acknowledge) }

  describe ".attributes_from" do
    let(:expiry_time) { Time.zone.parse("2030-01-01 12:00:00") }

    # Google state => [Pay status, ends at the period expiry?]
    {
      "SUBSCRIPTION_STATE_PENDING" => [ "incomplete", false ],
      "SUBSCRIPTION_STATE_ACTIVE" => [ "active", false ],
      "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" => [ "active", false ],
      "SUBSCRIPTION_STATE_ON_HOLD" => [ "past_due", false ],
      "SUBSCRIPTION_STATE_PAUSED" => [ "paused", false ],
      "SUBSCRIPTION_STATE_CANCELED" => [ "active", true ],
      "SUBSCRIPTION_STATE_EXPIRED" => [ "canceled", true ],
      "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED" => [ "incomplete_expired", false ]
    }.each do |state, (status, ends)|
      it "maps #{state} to #{status}" do
        attributes = described_class.attributes_from(google_subscription(account_id: "a", state: state, expiry_time: expiry_time))

        expect(attributes).to include(status: status, subscription_state: state, current_period_end: expiry_time)
        expect(attributes[:ends_at]).to eq(ends ? expiry_time : nil)
      end
    end

    it "maps every Google state" do
      expect(described_class::STATUSES.keys).to include(*%w[
        SUBSCRIPTION_STATE_PENDING SUBSCRIPTION_STATE_ACTIVE SUBSCRIPTION_STATE_IN_GRACE_PERIOD SUBSCRIPTION_STATE_ON_HOLD
        SUBSCRIPTION_STATE_PAUSED SUBSCRIPTION_STATE_CANCELED SUBSCRIPTION_STATE_EXPIRED
      ])
    end

    it "maps a revoked purchase to a subscription canceled now" do
      freeze_time do
        attributes = described_class.attributes_from(google_subscription(account_id: "a", state: "SUBSCRIPTION_STATE_EXPIRED"), revoked: true)

        expect(attributes).to include(status: "canceled", ends_at: Time.current, revoked_at: Time.current.iso8601)
      end
    end

    it "uses the product id as Pay plan and keeps the base plan" do
      attributes = described_class.attributes_from(google_subscription(account_id: "a", product_id: "family", base_plan_id: "yearly"))

      expect(attributes).to include(processor_plan: "family", base_plan_id: "yearly", name: "default", auto_renewing: true)
    end

    it "names the subscription with Tillbell.subscription_name" do
      original = Tillbell.subscription_name
      Tillbell.subscription_name = ->(product_id:, base_plan_id:) { "#{product_id}-#{base_plan_id}" }

      expect(described_class.attributes_from(google_subscription(account_id: "a"))[:name]).to eq("premium-monthly")
    ensure
      Tillbell.subscription_name = original
    end

    it "refuses an unknown state" do
      expect { described_class.attributes_from(google_subscription(account_id: "a", state: "SUBSCRIPTION_STATE_NEW")) }
        .to raise_error(Tillbell::Error, /Unknown Google Play subscription state/)
    end
  end

  describe ".sync" do
    def sync(**response_options)
      stub_google_subscription(token, google_subscription(account_id: account_id, **response_options))
      described_class.sync(token)
    end

    it "records a new purchase as an active Pay subscription and emits subscription_created" do
      events = tillbell_events { sync }

      subscription = described_class.sole
      expect(subscription).to have_attributes(processor_id: token, processor_plan: "premium", base_plan_id: "monthly", customer: user.pay_customers.sole)
      expect(subscription).to be_active
      expect(events).to eq([ [ :subscription_created, subscription ] ])
    end

    it "is visible through the owner's Pay associations" do
      sync

      expect(user.pay_subscriptions.active).to eq([ described_class.sole ])
    end

    describe "detailed events" do
      def names(events) = events.map(&:first)

      it "emits subscription_renewed with subscription_updated when a new period starts" do
        sync(expiry_time: 1.month.from_now)

        expect(names(tillbell_events { sync(expiry_time: 2.months.from_now) })).to eq(%i[subscription_updated subscription_renewed])
      end

      it "does not call the first activation of a pending purchase a renewal" do
        sync(state: "SUBSCRIPTION_STATE_PENDING", expiry_time: 1.month.from_now)

        expect(names(tillbell_events { sync(expiry_time: 2.months.from_now) })).to eq(%i[subscription_updated])
      end

      it "emits payment_failed on the first failure only, not again when the grace period turns into a hold" do
        sync

        expect(names(tillbell_events { sync(state: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD") })).to eq(%i[subscription_updated payment_failed])
        expect(names(tillbell_events { sync(state: "SUBSCRIPTION_STATE_ON_HOLD") })).to eq(%i[subscription_updated])
        expect(tillbell_events { sync(state: "SUBSCRIPTION_STATE_ON_HOLD") }).to be_empty
      end

      it "emits no detailed event for a refunded or replaced subscription read late" do
        sync
        described_class.sync(token, revoked: true)

        expect(names(tillbell_events { sync(state: "SUBSCRIPTION_STATE_ON_HOLD") })).to eq(%i[subscription_updated])
        expect(names(tillbell_events { sync(expiry_time: 3.months.from_now) })).to eq(%i[subscription_updated])
      end

      it "emits plan_changed for another base plan of the same product" do
        sync
        stub_google_subscription("new-token", google_subscription(account_id: account_id, base_plan_id: "yearly", linked_purchase_token: token))

        expect(names(tillbell_events { described_class.sync("new-token") })).to eq(%i[subscription_created subscription_expired plan_changed])
      end

      it "still emits plan_changed when a notification about the old token ended it before the new purchase was known" do
        sync
        sync(state: "SUBSCRIPTION_STATE_EXPIRED", expiry_time: 1.minute.ago)
        stub_google_subscription("new-token", google_subscription(account_id: account_id, product_id: "family", linked_purchase_token: token))

        events = names(tillbell_events { described_class.sync("new-token") })

        expect(events).to eq(%i[subscription_created plan_changed])
        expect(described_class.find_by!(processor_id: token)).to be_replaced
      end

      it "emits payment_recovered, and subscription_renewed, when the payment goes through" do
        expiry = 1.month.from_now
        sync(state: "SUBSCRIPTION_STATE_ON_HOLD", expiry_time: expiry)

        events = names(tillbell_events { sync(expiry_time: expiry + 1.month) })

        expect(events).to eq(%i[subscription_updated subscription_renewed payment_recovered])
      end

      it "emits plan_changed when the product of a purchase changes in place" do
        # Both syncs must report the same expiry, or the change also reads as a renewal.
        freeze_time
        sync(product_id: "premium")

        expect(names(tillbell_events { sync(product_id: "basic") })).to eq(%i[subscription_updated plan_changed])
      end

      it "emits plan_changed once, after the replacement, for a purchase that replaces another product" do
        sync
        stub_google_subscription("new-token", google_subscription(account_id: account_id, product_id: "family", linked_purchase_token: token))

        events = tillbell_events { described_class.sync("new-token") }
        new = described_class.find_by!(processor_id: "new-token")

        expect(names(events)).to eq(%i[subscription_created subscription_expired plan_changed])
        expect(events.last.last).to eq(new)
        expect(new.replaced_subscription).to eq(described_class.find_by!(processor_id: token))
        expect(tillbell_events { described_class.sync("new-token") }).to be_empty
      end

      it "does not emit plan_changed for a customer who signs up again for the same product" do
        sync
        stub_google_subscription("new-token", google_subscription(account_id: account_id, linked_purchase_token: token))

        expect(names(tillbell_events { described_class.sync("new-token") })).to eq(%i[subscription_created subscription_expired])
      end

      it "emits nothing more than subscription_revoked for a refund" do
        sync

        expect(names(tillbell_events { described_class.sync(token, revoked: true) })).to eq(%i[subscription_revoked])
      end
    end

    it "gives a digest of the purchase token that is not the token" do
      subscription = sync

      expect(subscription.token_digest).to match(/\A\h{16}\z/).and eq(Digest::SHA256.hexdigest(token).first(16))
    end

    it "finds its plan in Tillbell.plans" do
      subscription = sync(product_id: "premium", base_plan_id: "yearly")
      original = Tillbell.plans
      Tillbell.plans = [ { name: :pro, product_id: "premium", base_plan_id: "yearly" } ]

      expect(subscription.plan.name).to eq(:pro)
    ensure
      Tillbell.plans = original
    end

    it "is billing while it renews, is retried or is paused, and not once it ended" do
      sync
      subscription = described_class.sole

      expect(subscription).to be_billing
      %w[past_due paused].each { |status| expect(subscription.tap { _1.status = status }).to be_billing }
      expect(subscription.tap { _1.status = "canceled"; _1.ends_at = 1.day.ago }).not_to be_billing
    end

    it "grants access while it renews or is in its grace period, not on hold, paused or pending" do
      {
        "SUBSCRIPTION_STATE_ACTIVE" => true, "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" => true, "SUBSCRIPTION_STATE_CANCELED" => true,
        "SUBSCRIPTION_STATE_ON_HOLD" => false, "SUBSCRIPTION_STATE_PAUSED" => false, "SUBSCRIPTION_STATE_PENDING" => false,
        "SUBSCRIPTION_STATE_EXPIRED" => false
      }.each do |state, access|
        sync(state: state)
        expect(described_class.sole.grants_access?).to be(access), state
      end
    end

    it "is owned while Google holds the purchase, even without access, and not once it ended" do
      {
        "SUBSCRIPTION_STATE_PAUSED" => true, "SUBSCRIPTION_STATE_PENDING" => true, "SUBSCRIPTION_STATE_ON_HOLD" => true,
        "SUBSCRIPTION_STATE_CANCELED" => true, "SUBSCRIPTION_STATE_EXPIRED" => false,
        "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED" => false
      }.each do |state, owned|
        sync(state: state)
        expect(described_class.sole.owned?).to be(owned), state
      end
    end

    it "is no longer owned once refunded or replaced, whatever Google reports" do
      sync(state: "SUBSCRIPTION_STATE_PAUSED")
      subscription = described_class.sole

      expect(subscription.tap { _1.revoked_at = Time.current.iso8601 }).not_to be_owned
      expect(subscription.tap { _1.revoked_at = nil; _1.replaced_by = "new-token" }).not_to be_owned
      expect(subscription.tap { _1.replaced_by = nil; _1.subscription_state = nil }).not_to be_owned
    end

    it "changes nothing and emits nothing when the same state is synced twice" do
      # The default expiry is relative to now: two syncs a second apart would report a renewal.
      freeze_time
      sync
      expect { expect(tillbell_events { sync }).to be_empty }.not_to change { described_class.sole.updated_at }
    end

    it "advances the period end on renewal" do
      renewal = 2.months.from_now
      sync(expiry_time: 1.month.from_now)
      events = tillbell_events { sync(expiry_time: renewal) }

      expect(described_class.sole.current_period_end).to be_within(1.second).of(renewal)
      expect(events.map(&:first)).to eq([ :subscription_updated, :subscription_renewed ])
    end

    it "keeps access until the period end after a cancellation" do
      sync
      events = tillbell_events { sync(state: "SUBSCRIPTION_STATE_CANCELED", auto_renewing: false) }

      subscription = described_class.sole
      expect(subscription).to be_active.and be_on_grace_period
      expect(subscription.ends_at).to eq(subscription.current_period_end)
      expect(events.map(&:first)).to eq([ :subscription_canceled ])
    end

    it "keeps access during the grace period and suspends it on hold" do
      sync
      sync(state: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD")
      expect(described_class.sole).to be_active.and be_in_grace_period

      sync(state: "SUBSCRIPTION_STATE_ON_HOLD")
      expect(described_class.sole).not_to be_active
      expect(described_class.sole).to be_past_due.and be_on_hold
    end

    it "pauses the subscription" do
      sync
      sync(state: "SUBSCRIPTION_STATE_PAUSED")

      expect(described_class.sole).to be_paused
      expect(described_class.sole).not_to be_active
    end

    it "emits subscription_expired once the subscription expires" do
      sync
      events = tillbell_events { sync(state: "SUBSCRIPTION_STATE_EXPIRED", expiry_time: 1.minute.ago) }

      expect(described_class.sole).not_to be_active
      expect(events.map(&:first)).to eq([ :subscription_expired ])
    end

    it "revokes a refunded purchase once, and keeps it revoked" do
      sync
      stub_google_subscription(token, google_subscription(account_id: account_id, state: "SUBSCRIPTION_STATE_EXPIRED"))

      events = tillbell_events { described_class.sync(token, revoked: true) }
      ended_at = described_class.sole.ends_at
      repeated = tillbell_events do
        described_class.sync(token, revoked: true)
        described_class.sync(token)
      end

      subscription = described_class.sole
      expect(subscription).to be_revoked
      expect(subscription).not_to be_active
      expect(subscription.ends_at).to eq(ended_at)
      expect(subscription.status).to eq("canceled")
      expect(events.map(&:first)).to eq([ :subscription_revoked ])
      expect(repeated).to be_empty
    end

    it "ends in the same state whatever the order notifications arrive in, since it always reads Google" do
      final_state = google_subscription(account_id: account_id, state: "SUBSCRIPTION_STATE_CANCELED", auto_renewing: false)
      stub_google_subscription(token, final_state)

      2.times { described_class.sync(token) }
      first = described_class.sole.attributes.except("updated_at")

      described_class.delete_all
      3.times { described_class.sync(token, object: final_state) }

      expect(described_class.sole.attributes.except("id", "created_at", "updated_at")).to eq(first.except("id", "created_at"))
    end

    it "retires the previous subscription on a plan change" do
      sync
      stub_google_subscription("new-token", google_subscription(account_id: account_id, base_plan_id: "yearly", linked_purchase_token: token))

      events = tillbell_events { described_class.sync("new-token") }

      old, new = described_class.find_by!(processor_id: token), described_class.find_by!(processor_id: "new-token")
      expect(old).not_to be_active
      expect(new).to be_active
      expect(new.base_plan_id).to eq("yearly")
      expect(events).to contain_exactly([ :subscription_created, new ], [ :subscription_expired, old ], [ :plan_changed, new ])
    end

    it "acknowledges a purchase that grants access and is not acknowledged yet" do
      sync(acknowledged: false)

      expect(Tillbell::GooglePlay).to have_received(:acknowledge).with("premium", token).once
    end

    it "does not acknowledge an acknowledged or pending purchase" do
      sync(acknowledged: true)
      sync(acknowledged: false, state: "SUBSCRIPTION_STATE_PENDING")

      expect(Tillbell::GooglePlay).not_to have_received(:acknowledge)
    end

    it "ignores a purchase that was not made through Tillbell" do
      stub_google_subscription(token, google_subscription(account_id: "unknown"))

      expect(described_class.sync(token)).to be_nil
      expect(described_class.count).to eq(0)
    end

    it "saves the subscription even when a callback fails" do
      allow(Rails.error).to receive(:report)
      subscriber = Tillbell.on(:subscription_created) { raise "boom" }

      expect { sync }.not_to raise_error
      expect(described_class.sole).to be_active
      expect(Rails.error).to have_received(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "recovers when another process inserted the same purchase first" do
      sync
      stale = described_class.new(customer: user.pay_customers.sole, processor_id: token)
      calls = 0
      allow_any_instance_of(ActiveRecord::Relation).to receive(:find_or_initialize_by).and_wrap_original do |original, *args|
        (calls += 1) == 1 ? stale : original.call(*args)
      end

      renewal = 2.months.from_now
      expect { sync(expiry_time: renewal) }.not_to raise_error
      expect(described_class.sole.current_period_end).to be_within(1.second).of(renewal)
    end

    it "keeps Google's last answer for debugging" do
      sync

      expect(described_class.sole.object).to include("subscription_state" => "SUBSCRIPTION_STATE_ACTIVE")
    end
  end

  describe "Pay API" do
    let(:subscription) do
      stub_google_subscription(token, google_subscription(account_id: account_id))
      described_class.sync(token)
    end

    it "cancels the renewal with Google, then reads the new state" do
      allow(Tillbell::GooglePlay).to receive(:cancel)
      subscription
      stub_google_subscription(token, google_subscription(account_id: account_id, state: "SUBSCRIPTION_STATE_CANCELED"))

      subscription.cancel_now!

      expect(Tillbell::GooglePlay).to have_received(:cancel).with("premium", token)
      expect(subscription.reload).to be_canceled.and be_active
    end

    it "does not ask Google to cancel a subscription that already stopped renewing" do
      allow(Tillbell::GooglePlay).to receive(:cancel)
      stub_google_subscription(token, google_subscription(account_id: account_id, state: "SUBSCRIPTION_STATE_CANCELED", auto_renewing: false))
      canceled = described_class.sync(token)

      expect { canceled.cancel_now! }.not_to raise_error
      expect(Tillbell::GooglePlay).not_to have_received(:cancel)
    end

    it "is told apart from the other processors' subscriptions" do
      other = Pay::FakeProcessor::Subscription.create!(customer: user.set_payment_processor(:fake_processor, allow_fake: true),
        name: "default", processor_id: "sub_1", processor_plan: "plan", status: "active")

      expect(subscription).to be_google_play
      expect(other).not_to be_google_play
      expect(Pay::Subscription.google_play).to contain_exactly(subscription)
    end

    it "refuses changes that only the app or the Play Store can make" do
      %i[swap pause resume change_quantity].each do |method_name|
        expect { subscription.public_send(method_name, "x") }.to raise_error(Tillbell::Error, /Play Store/)
      end
    end
  end

  describe "details Google reports" do
    def sync_with(token_name = token, **options)
      stub_google_subscription(token_name, google_subscription(account_id: account_id, **options))
      described_class.sync(token_name)
    end

    def price(units, nanos, currency) = { units: units, nanos: nanos, currency_code: currency }

    describe "#price_amount and #price_currency" do
      it "give the price of one renewal in the units of its currency, from Google's answer" do
        subscription = sync_with(recurring_price: price(12, 990_000_000, "EUR"))

        expect(subscription.price_amount).to eq(BigDecimal("12.99"))
        expect(subscription.price_amount).to be_a(BigDecimal)
        expect(subscription.price_currency).to eq("EUR")
      end

      it "do not assume two decimals: yen have none, dinars have three" do
        expect(sync_with("yen", recurring_price: price(1200, 0, "JPY")).price_amount).to eq(1200)
        expect(sync_with("dinar", recurring_price: price(1, 234_000_000, "KWD")).price_amount).to eq(BigDecimal("1.234"))
      end

      it "work the same once the subscription is read back from the database" do
        sync_with(recurring_price: price("4", 990_000_000, "USD"))

        reloaded = described_class.sole
        expect([ reloaded.price_amount, reloaded.price_currency ]).to eq([ BigDecimal("4.99"), "USD" ])
      end

      it "are nil when Google gives no price" do
        subscription = sync_with

        expect([ subscription.price_amount, subscription.price_currency ]).to eq([ nil, nil ])
      end
    end

    describe "replacements" do
      it "knows a purchase that replaces another, and the one it replaced" do
        old = sync_with("old-token", product_id: "solo")
        replacement = sync_with("new-token", product_id: "family", linked_purchase_token: "old-token")

        expect(replacement).to be_replacement
        expect(replacement.linked_purchase_token).to eq("old-token")
        expect(old).not_to be_replacement
        expect(old.reload).to be_replaced
        expect(replacement).not_to be_replaced
      end

      it "already knows the subscription is replaced when the subscription_expired event fires" do
        sync_with("old-token", product_id: "solo")
        seen = []
        subscriber = ActiveSupport::Notifications.subscribe("pay.tillbell.subscription_expired") { |*, subscription| seen << subscription.replaced? }

        sync_with("new-token", product_id: "family", linked_purchase_token: "old-token")

        expect(seen).to eq([ true ])
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      it "does not call a lone subscription replaced" do
        expect(sync_with).not_to be_replaced
      end
    end

    # Google lists two line items on the NEW token of a deferred plan change, see
    # https://developer.android.com/google/play/billing/subscriptions#deferred-replacement
    describe "a deferred plan change" do
      def family_to_solo_items(in_force:)
        ended = { product_id: "family", expiry_time: 1.day.ago.utc.iso8601, auto_renewing_plan: { recurring_price: price(9, 990_000_000, "EUR") } }
        pending = { product_id: "family", expiry_time: 1.week.from_now.utc.iso8601, offer_details: { base_plan_id: "monthly" },
                    auto_renewing_plan: { auto_renew_enabled: false, recurring_price: price(9, 990_000_000, "EUR") },
                    deferred_item_replacement: { product_id: "solo" } }
        incoming = { product_id: "solo", offer_details: { base_plan_id: "monthly" } }
        renewed = { product_id: "solo", expiry_time: 1.month.from_now.utc.iso8601, offer_details: { base_plan_id: "monthly" },
                    auto_renewing_plan: { auto_renew_enabled: true, recurring_price: price(4, 990_000_000, "EUR") } }
        in_force == :before ? [ pending, incoming ] : [ ended, renewed ]
      end

      it "keeps the current product, price and pending change until the renewal" do
        subscription = sync_with(linked_purchase_token: "old-token", line_items: family_to_solo_items(in_force: :before))

        expect(subscription.processor_plan).to eq("family")
        expect(subscription).to be_plan_change_pending
        expect(subscription.deferred_product_id).to eq("solo")
        expect(subscription.price_amount).to eq(BigDecimal("9.99"))
        expect(described_class.find(subscription.id).deferred_product_id).to eq("solo")
      end

      it "moves to the new product at the renewal and no longer reports a pending change" do
        sync_with(linked_purchase_token: "old-token", line_items: family_to_solo_items(in_force: :before))

        subscription = sync_with(linked_purchase_token: "old-token", line_items: family_to_solo_items(in_force: :after))

        expect(subscription.processor_plan).to eq("solo")
        expect(subscription).not_to be_plan_change_pending
        expect(subscription.price_amount).to eq(BigDecimal("4.99"))
      end

      it "reports no pending change on a plain subscription" do
        expect(sync_with("plain-token")).not_to be_plan_change_pending
      end
    end

    it "#manage_url points to the Play Store page of the product" do
      allow(Tillbell).to receive(:google).and_return(ActiveSupport::OrderedOptions.new.merge(package_name: "com.example.app"))

      expect(sync_with(product_id: "premium").manage_url)
        .to eq("https://play.google.com/store/account/subscriptions?sku=premium&package=com.example.app")
    end
  end

  describe "cancelling a subscription Google no longer knows" do
    let(:expired) do
      stub_google_subscription(token, google_subscription(account_id: account_id, state: "SUBSCRIPTION_STATE_EXPIRED", expiry_time: 3.months.ago))
      described_class.sync(token)
    end

    it "does not call Google for an ended subscription" do
      expired
      allow(Tillbell::GooglePlay).to receive(:cancel)
      allow(Tillbell::GooglePlay).to receive(:subscription).and_raise(google_error(Google::Apis::ClientError, 410))

      expect { expired.cancel_now! }.not_to raise_error
      expect(Tillbell::GooglePlay).not_to have_received(:cancel)
    end

    it "records a stale active row as ended when Google answers 410, instead of failing the deletion of its owner" do
      stub_google_subscription(token, google_subscription(account_id: account_id, expiry_time: 3.months.ago))
      stale = described_class.sync(token)
      allow(Tillbell::GooglePlay).to receive(:cancel).and_raise(google_error(Google::Apis::ClientError, 410))

      events = tillbell_events { expect { stale.cancel_now! }.not_to raise_error }

      expect(stale.reload).to have_attributes(status: "canceled")
      expect(stale.ends_at).to be_within(1.minute).of(3.months.ago)
      expect(events.map(&:first)).to eq([ :subscription_expired ])
    end

    it "does the same when the refresh fails because the subscription no longer renews" do
      stub_google_subscription(token, google_subscription(account_id: account_id, state: "SUBSCRIPTION_STATE_CANCELED", expiry_time: 3.months.from_now, auto_renewing: false))
      stale = described_class.sync(token)
      allow(Tillbell::GooglePlay).to receive(:cancel)
      allow(Tillbell::GooglePlay).to receive(:subscription).and_raise(google_error(Google::Apis::ClientError, 410))

      expect { stale.cancel_now! }.not_to raise_error
      expect(Tillbell::GooglePlay).not_to have_received(:cancel)
      expect(stale.reload).to be_canceled
    end

    it "emits subscription_expired once: a row already ended is left alone" do
      expired
      allow(Tillbell::GooglePlay).to receive(:subscription).and_raise(google_error(Google::Apis::ClientError, 410))

      events = tillbell_events { expired.cancel }

      expect(events).to be_empty
    end

    # A wrong package name or a bad request does not mean the subscription is gone: it may
    # still be billing, so the failure must be visible.
    [ 400, 403, 404 ].each do |status|
      it "still raises on a #{status}, which is no sign the subscription is gone" do
        stub_google_subscription(token, google_subscription(account_id: account_id))
        subscription = described_class.sync(token)
        allow(Tillbell::GooglePlay).to receive(:cancel).and_raise(google_error(Google::Apis::ClientError, status))

        expect { subscription.cancel_now! }.to raise_error(Tillbell::Error, /refused to stop the renewal/) do |error|
          expect(error.cause).to be_a(Google::Apis::ClientError)
        end
        expect(subscription.reload).to be_active
      end
    end

    it "raises a Tillbell::Error when Google's token server fails" do
      stub_google_subscription(token, google_subscription(account_id: account_id))
      subscription = described_class.sync(token)
      allow(Tillbell::GooglePlay).to receive(:cancel).and_raise(Signet::RemoteServerError.new("503"))

      expect { subscription.cancel_now! }.to raise_error(Tillbell::Error)
    end

    it "raises a Tillbell::Error when the service account key was revoked" do
      stub_google_subscription(token, google_subscription(account_id: account_id))
      subscription = described_class.sync(token)
      allow(Tillbell::GooglePlay).to receive(:cancel).and_raise(Signet::AuthorizationError.new("invalid_grant"))

      expect { subscription.cancel_now! }.to raise_error(Pay::Error, /invalid_grant/)
    end

    it "stops the renewal of a subscription with a deferred plan change waiting, whose entitlement in force no longer renews" do
      pending = { product_id: "family", expiry_time: 1.week.from_now.utc.iso8601, offer_details: { base_plan_id: "monthly" },
                  auto_renewing_plan: { auto_renew_enabled: false }, deferred_item_replacement: { product_id: "solo" } }
      stub_google_subscription(token, google_subscription(account_id: account_id, line_items: [ pending, { product_id: "solo" } ]))
      subscription = described_class.sync(token)
      allow(Tillbell::GooglePlay).to receive(:cancel)

      subscription.cancel_now!

      expect(subscription.auto_renewing).to be(false)
      expect(Tillbell::GooglePlay).to have_received(:cancel).with("family", token)
    end
  end

  describe "a replaced subscription" do
    it "stays ended when Google later reads its old token as still active" do
      stub_google_subscription("old-token", google_subscription(account_id: account_id, product_id: "family"))
      described_class.sync("old-token")
      stub_google_subscription("new-token", google_subscription(account_id: account_id, product_id: "family", linked_purchase_token: "old-token"))
      described_class.sync("new-token")

      events = tillbell_events { described_class.sync("old-token") }

      expect(described_class.find_by(processor_id: "old-token")).to be_canceled.and(be_replaced)
      expect(events.map(&:first)).to be_empty
    end
  end
end
