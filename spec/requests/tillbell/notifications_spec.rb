RSpec.describe "POST /tillbell/notifications/google_play" do
  let(:endpoint) { "http://www.example.com/tillbell/notifications/google_play" }
  let(:claims) { { "email" => "pubsub@example.iam.gserviceaccount.com", "email_verified" => true } }

  before do
    allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_raise(Google::Auth::IDTokens::SignatureError, "bad signature")
    allow(Google::Auth::IDTokens).to receive(:verify_oidc).with("valid", aud: endpoint).and_return(claims)
  end

  # Posts a Pub/Sub push request wrapping +notification+.
  def push(notification, authorization: "Bearer valid")
    body = { message: { data: [ notification.to_json ].pack("m0"), messageId: "1" }, subscription: "projects/p/subscriptions/s" }
    post "/tillbell/notifications/google_play", params: body, as: :json, headers: { "Authorization" => authorization }.compact
  end

  def subscription_notification(type, token: "purchase-token", package_name: "com.example.app")
    { version: "1.0", packageName: package_name, eventTimeMillis: "1700000000000",
      subscriptionNotification: { version: "1.0", notificationType: type, purchaseToken: token } }
  end

  it "rejects a request without an OIDC token" do
    push(subscription_notification(2), authorization: nil)

    expect(response).to have_http_status(:unauthorized)
    expect(Pay::Webhook.count).to eq(0)
  end

  it "rejects a token Google did not sign for this endpoint" do
    push(subscription_notification(2), authorization: "Bearer forged")

    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects a token issued for another service account" do
    claims["email"] = "someone@example.com"

    push(subscription_notification(2))

    expect(response).to have_http_status(:unauthorized)
  end

  it "checks the configured audience when the endpoint is behind a proxy" do
    Tillbell.google.pubsub_audience = "https://example.com/push"
    allow(Google::Auth::IDTokens).to receive(:verify_oidc).with("valid", aud: "https://example.com/push").and_return(claims)

    push(subscription_notification(2))

    expect(response).to have_http_status(:ok)
  ensure
    Tillbell.google.pubsub_audience = nil
  end

  it "rejects a malformed message" do
    post "/tillbell/notifications/google_play", params: { message: { data: "not base64 json" } }, as: :json,
      headers: { "Authorization" => "Bearer valid" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "stores a subscription notification in Pay and processes it later" do
    push(subscription_notification(2))

    expect(response).to have_http_status(:ok)
    webhook = Pay::Webhook.sole
    expect(webhook).to have_attributes(processor: "google_play", event_type: "subscription_notification")
    expect(Pay::Webhooks::ProcessJob).to have_been_enqueued.with(webhook)
  end

  it "re-reads the subscription from Google when Pay processes the notification" do
    push(subscription_notification(2))

    perform_enqueued_jobs(only: Pay::Webhooks::ProcessJob)

    expect(Tillbell::SyncJob).to have_been_enqueued.with("purchase-token", revoked: false)
  end

  it "flags a revoked subscription" do
    push(subscription_notification(Tillbell::GooglePlay::SUBSCRIPTION_REVOKED))

    perform_enqueued_jobs(only: Pay::Webhooks::ProcessJob)

    expect(Tillbell::SyncJob).to have_been_enqueued.with("purchase-token", revoked: true)
  end

  it "revokes a voided subscription purchase" do
    push({ packageName: "com.example.app", voidedPurchaseNotification: { purchaseToken: "purchase-token", productType: 1, refundType: 1 } })

    perform_enqueued_jobs(only: Pay::Webhooks::ProcessJob)

    expect(Tillbell::SyncJob).to have_been_enqueued.with("purchase-token", revoked: true)
  end

  it "acknowledges and ignores a voided one-time purchase" do
    push({ packageName: "com.example.app", voidedPurchaseNotification: { purchaseToken: "t", productType: 2, refundType: 1 } })

    expect(response).to have_http_status(:ok)
    expect(Pay::Webhook.count).to eq(0)
  end

  it "answers the Play Console test notification" do
    push({ version: "1.0", packageName: "com.example.app", testNotification: { version: "1.0" } })

    expect(response).to have_http_status(:ok)
    expect(Pay::Webhook.count).to eq(0)
  end

  it "acknowledges and ignores unknown notifications and other apps' notifications" do
    push({ packageName: "com.example.app", somethingNew: {} })
    push(subscription_notification(2, package_name: "com.other.app"))

    expect(response).to have_http_status(:ok)
    expect(Pay::Webhook.count).to eq(0)
  end

  it "never logs the full purchase token" do
    output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)

    push(subscription_notification(2, token: "secret-purchase-token"))

    expect(output.string).to include("notification subscription_notification type=2 token=secret-p...")
    expect(output.string).not_to include("secret-purchase-token")
  ensure
    Rails.logger = original_logger
  end
end
