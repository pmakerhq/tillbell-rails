RSpec.describe "POST /tillbell/purchases" do
  let(:user) { User.create!(email: "ada@example.com") }
  let(:account_id) { Pay::GooglePlay::Customer.for(user).processor_id }
  let(:token) { "purchase-token" }

  before { allow(Tillbell::GooglePlay).to receive(:acknowledge) }

  def post_purchase(params = { purchase_token: token }, signed_in: user)
    post "/tillbell/purchases", params: params, as: :json, headers: { "X-User-Id" => signed_in&.id.to_s }
  end

  it "requires a signed-in owner" do
    post_purchase(signed_in: nil)

    expect(response).to have_http_status(:unauthorized)
  end

  it "requires a purchase token" do
    post_purchase({})

    expect(response).to have_http_status(:bad_request)
  end

  it "verifies the purchase with Google, records it and acknowledges it" do
    stub_google_subscription(token, google_subscription(account_id: account_id, acknowledged: false))

    post_purchase

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "verified", "active" => true, "subscription_status" => "active")
    expect(user.pay_subscriptions.active.sole.processor_id).to eq(token)
    expect(Tillbell::GooglePlay).to have_received(:acknowledge).with("premium", token)
  end

  it "records a pending purchase without granting access" do
    stub_google_subscription(token, google_subscription(account_id: account_id, state: "SUBSCRIPTION_STATE_PENDING"))

    post_purchase

    expect(response.parsed_body).to include("status" => "verified", "active" => false, "subscription_status" => "incomplete")
  end

  it "creates a single subscription when the same token is posted twice" do
    stub_google_subscription(token, google_subscription(account_id: account_id))

    2.times { post_purchase }

    expect(Pay::GooglePlay::Subscription.count).to eq(1)
  end

  it "refuses a purchase made by another account and tells the host app" do
    other = User.create!(email: "grace@example.com")
    stub_google_subscription(token, google_subscription(account_id: Pay::GooglePlay::Customer.for(other).processor_id))

    events = tillbell_events { post_purchase }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("status" => "rejected")
    expect(Pay::GooglePlay::Subscription.count).to eq(0)
    expect(events).to eq([ [ :purchase_rejected, { owner: user, purchase_token: "purchase..." } ] ])
  end

  it "ignores any customer id posted by the client" do
    other = User.create!(email: "grace@example.com")
    stub_google_subscription(token, google_subscription(account_id: account_id))

    post_purchase({ purchase_token: token, customer_id: other.id, account_id: Pay::GooglePlay::Customer.for(other).processor_id })

    expect(user.pay_subscriptions.count).to eq(1)
    expect(other.pay_subscriptions.count).to eq(0)
  end

  it "refuses a token Google does not know" do
    allow(Tillbell::GooglePlay).to receive(:subscription).and_raise(google_error(Google::Apis::ClientError, 404))

    post_purchase

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("status" => "invalid")
  end

  it "fails loudly when the service account cannot read purchases" do
    allow(Tillbell::GooglePlay).to receive(:subscription).and_raise(google_error(Google::Apis::ClientError, 403))

    expect { post_purchase }.to raise_error(Google::Apis::ClientError)
  end

  [ Google::Apis::ServerError, Google::Apis::RateLimitError, Google::Apis::TransmissionError ].each do |error_class|
    it "verifies the purchase in the background when Google fails with #{error_class.name.demodulize}" do
      allow(Tillbell::GooglePlay).to receive(:subscription).and_raise(google_error(error_class, 503))

      post_purchase

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to eq("status" => "verifying")
      expect(Tillbell::SyncJob).to have_been_enqueued.with(token)
    end
  end

  it "never logs the full purchase token" do
    output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    stub_google_subscription(token, google_subscription(account_id: account_id))

    post_purchase

    expect(output.string).not_to include(token)
  ensure
    Rails.logger = original_logger
  end
end
