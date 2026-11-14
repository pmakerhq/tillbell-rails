RSpec.describe "App Store purchases and notifications" do
  let(:user) { User.create!(email: "ada@example.com") }
  let(:account_id) { Pay::GooglePlay::Customer.for(user).processor_id }

  def post_purchase(jws, signed_in: user)
    post "/tillbell/purchases", params: { purchase_token: jws }, as: :json, headers: { "X-User-Id" => signed_in&.id.to_s }
  end

  def post_notification(signed_payload)
    post "/tillbell/notifications/app_store", params: { signedPayload: signed_payload }, as: :json
  end

  describe "POST /tillbell/purchases" do
    it "verifies Apple's signature and records the subscription without calling anyone" do
      events = tillbell_events { post_purchase(app_store_jws(app_store_transaction(account_id: account_id))) }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("status" => "verified", "active" => true, "subscription_status" => "active")
      subscription = user.pay_subscriptions.active.sole
      expect(subscription).to be_a(Pay::AppStore::Subscription)
      expect(subscription).to have_attributes(processor_id: "2000000000000001", processor_plan: "premium.monthly", ends_at: nil)
      expect(subscription).to be_app_store
      expect(subscription.customer.processor_id).to eq(account_id)
      expect(events.map(&:first)).to eq([ :subscription_created ])
    end

    it "accepts the appAccountToken in upper case, as StoreKit formats a UUID" do
      post_purchase(app_store_jws(app_store_transaction(account_id: account_id.upcase)))

      expect(response.parsed_body).to include("status" => "verified")
    end

    it "keeps one subscription when the same transaction is posted again, as restore does" do
      jws = app_store_jws(app_store_transaction(account_id: account_id))

      2.times { post_purchase(jws) }

      expect(Pay::AppStore::Subscription.count).to eq(1)
    end

    it "refuses a transaction made by another account and tells the host app" do
      other = User.create!(email: "grace@example.com")
      jws = app_store_jws(app_store_transaction(account_id: Pay::GooglePlay::Customer.for(other).processor_id))

      events = tillbell_events { post_purchase(jws) }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("status" => "rejected")
      expect(Pay::AppStore::Subscription.count).to eq(0)
      expect(events.map(&:first)).to eq([ :purchase_rejected ])
    end

    it "refuses a transaction without an appAccountToken" do
      post_purchase(app_store_jws(app_store_transaction(account_id: nil)))

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a transaction Apple did not sign" do
      post_purchase(app_store_jws(app_store_transaction(account_id: account_id), chain: AppStoreHelpers.chain))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("status" => "invalid")
      expect(Pay::AppStore::Subscription.count).to eq(0)
    end

    it "never calls Google for an App Store transaction" do
      allow(Tillbell::GooglePlay).to receive(:subscription)

      post_purchase(app_store_jws(app_store_transaction(account_id: account_id)))

      expect(Tillbell::GooglePlay).not_to have_received(:subscription)
    end
  end

  describe "Xcode StoreKit Testing" do
    after { Tillbell.apple.allow_xcode_transactions = nil }

    it "records a purchase Xcode signed when allowed, as the iOS app posts it" do
      Tillbell.apple.allow_xcode_transactions = true
      # Xcode signs with its own certificate, given in x5c like Apple's chain.
      key = OpenSSL::PKey::EC.generate("prime256v1")
      certificate = AppStoreHelpers.certificate("StoreKit Testing in Xcode", key)
      jws = JWT.encode(app_store_transaction(account_id: account_id, environment: "Xcode"), key, "ES256", { x5c: [ Base64.strict_encode64(certificate.to_der) ] })

      post_purchase(jws)

      expect(response.parsed_body).to include("status" => "verified", "active" => true)
      expect(Pay::AppStore::Subscription.sole).to be_sandbox
    end
  end

  describe "POST /tillbell/notifications/app_store" do
    let(:transaction) { app_store_transaction(account_id: account_id) }

    it "stores a signed notification and lets Pay process it" do
      post_notification(app_store_jws(app_store_notification("SUBSCRIBED", transaction: transaction, renewal_info: app_store_renewal_info)))

      expect(response).to have_http_status(:ok)
      expect(Pay::Webhook.sole).to have_attributes(processor: "app_store", event_type: "subscribed")

      perform_enqueued_jobs(only: Pay::Webhooks::ProcessJob)

      expect(user.pay_subscriptions.sole).to have_attributes(processor_id: "2000000000000001", status: "active")
    end

    it "renews the subscription" do
      Pay::AppStore::Subscription.sync(transaction)
      renewal = app_store_transaction(account_id: account_id, transaction_id: "2000000000000002", purchased_at: 1.month.from_now, expires_at: 2.months.from_now)

      events = tillbell_events do
        post_notification(app_store_jws(app_store_notification("DID_RENEW", transaction: renewal, renewal_info: app_store_renewal_info)))
        perform_enqueued_jobs(only: Pay::Webhooks::ProcessJob)
      end

      expect(events.map(&:first)).to eq([ :subscription_updated, :subscription_renewed ])
      expect(Pay::AppStore::Subscription.sole.current_period_end).to be_within(1.second).of(2.months.from_now)
    end

    it "refuses an unsigned notification" do
      post_notification(app_store_jws(app_store_notification("DID_RENEW", transaction: transaction), chain: AppStoreHelpers.chain))

      expect(response).to have_http_status(:unauthorized)
      expect(Pay::Webhook.count).to eq(0)
    end

    it "ignores notifications about other in-app purchases of the app" do
      consumable = transaction.merge("type" => "Consumable")
      post_notification(app_store_jws(app_store_notification("ONE_TIME_CHARGE", transaction: consumable)))

      expect { perform_enqueued_jobs(only: Pay::Webhooks::ProcessJob) }.not_to raise_error
      expect(Pay::AppStore::Subscription.count).to eq(0)
    end

    it "acknowledges a summary notification, whose app is under summary" do
      post_notification(app_store_jws({ "notificationType" => "RENEWAL_EXTENSION", "subtype" => "SUMMARY",
                                        "summary" => { "bundleId" => AppStoreHelpers::BUNDLE_ID } }))

      expect(response).to have_http_status(:ok)
    end

    it "answers 401, not 500, to garbage" do
      header = Base64.urlsafe_encode64("null", padding: false)
      post_notification("#{header}.e30.c2ln")

      expect(response).to have_http_status(:unauthorized)
    end

    it "acknowledges a test notification without storing it" do
      post_notification(app_store_jws({ "notificationType" => "TEST", "data" => { "bundleId" => AppStoreHelpers::BUNDLE_ID } }))

      expect(response).to have_http_status(:ok)
      expect(Pay::Webhook.count).to eq(0)
    end
  end
end
