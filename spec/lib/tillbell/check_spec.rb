RSpec.describe Tillbell::Check do
  PEM = OpenSSL::PKey::RSA.generate(2048).to_pem unless defined?(PEM)

  let(:key) do
    { "type" => "service_account", "client_email" => "api@project.iam.gserviceaccount.com", "private_key" => PEM }
  end
  let(:google) do
    ActiveSupport::OrderedOptions.new.merge(
      package_name: "com.example.app", service_account_json: key.to_json,
      pubsub_service_account_email: "push@project.iam.gserviceaccount.com"
    )
  end

  before { allow(Tillbell).to receive(:google).and_return(google) }

  def run(**options) = described_class.new(**options).then { |check| [ check, check.call ] }

  def status_of(results, fragment) = results.find { |result| result.label.include?(fragment) }&.status

  def detail_of(results, fragment) = results.find { |result| result.label.include?(fragment) }&.detail

  def client_error(status, message = "no") = Google::Apis::ClientError.new(message, status_code: status)

  it "finds nothing to say about a complete configuration, and does not ask Google" do
    expect(Tillbell::GooglePlay).not_to receive(:service)

    check, results = run

    expect(check).to be_ok
    expect(results.map(&:status)).to all(eq(:ok))
  end

  it "never shows the private key" do
    _, results = run

    expect(results.flat_map { |result| [ result.label, result.detail ] }.join).not_to include(PEM.lines[1].strip, "PRIVATE KEY")
  end

  it "accepts the key as JSON text, or as a hash with string or symbol keys (Rails credentials give symbols)" do
    [ key, key.symbolize_keys ].each do |hash|
      google.service_account_json = hash

      expect(run.first).to be_ok
    end
  end

  it "reports where the engine is mounted, and fails when it is not" do
    expect(detail_of(run.last, "Engine mounted")).to include("/tillbell/purchases", "/tillbell/notifications/google_play")

    allow(Rails.application.routes).to receive(:routes).and_return([])

    expect(status_of(run.last, "Engine mounted")).to eq(:fail)
  end

  it "fails when the notification sender is missing, and says what it costs" do
    google.pubsub_service_account_email = nil

    check, results = run

    expect(check).not_to be_ok
    expect(detail_of(results, "Notification sender")).to include("401")
  end

  it "refuses an address that is not a service account" do
    google.pubsub_service_account_email = "me@example.com"

    expect(status_of(run.last, "Notification sender")).to eq(:fail)
  end

  it "warns when one account does everything" do
    google.pubsub_service_account_email = "api@project.iam.gserviceaccount.com"

    check, results = run

    expect(check).to be_ok
    expect(status_of(results, "Notification sender")).to eq(:warn)
  end

  describe "the key" do
    [
      [ "missing", nil ],
      [ "not JSON", "not json" ],
      [ "JSON but not an object", "[]" ],
      [ "without a private key", { "type" => "service_account", "client_email" => "a@b.iam.gserviceaccount.com" } ],
      [ "with a mangled private key", { "type" => "service_account", "client_email" => "a@b.iam.gserviceaccount.com", "private_key" => "-----BEGIN PRIVATE KEY-----\nSECRET\n-----END PRIVATE KEY-----\n" } ],
      [ "of another type", { "type" => "authorized_user", "client_email" => "a@b.iam.gserviceaccount.com", "private_key" => PEM } ],
      [ "without client_email", { "type" => "service_account", "private_key" => PEM } ]
    ].each do |description, bad|
      it "fails when it is #{description}" do
        google.service_account_json = bad.is_a?(Hash) ? bad.to_json : bad

        check, results = run

        expect(check).not_to be_ok
        expect(status_of(results, "Service account key")).to eq(:fail)
        expect(results.map(&:detail).join).not_to include("SECRET")
      end
    end
  end

  it "fails without a package name" do
    google.package_name = nil

    expect(run.first).not_to be_ok
  end

  describe "online" do
    let(:service) { double("AndroidPublisherService") }

    before do
      allow(Tillbell::GooglePlay).to receive(:service).and_return(service)
      # Google answers "unknown purchase" to the probe when reading purchases is allowed.
      allow(service).to receive(:get_purchase_subscriptionsv2).and_raise(client_error(404))
    end

    def subscription(product_id: "premium", plans: { "monthly" => "ACTIVE" })
      Google::Apis::AndroidpublisherV3::Subscription.new(
        product_id: product_id,
        base_plans: plans.map { |id, state| Google::Apis::AndroidpublisherV3::BasePlan.new(base_plan_id: id, state: state) }
      )
    end

    it "probes that purchases can be read with a token that cannot exist, and changes nothing" do
      allow(service).to receive(:get_monetization_subscription).and_return(subscription)

      _, results = run(online: true, plans: [ "premium:monthly" ])

      expect(status_of(results, "Reading purchases")).to eq(:ok)
      expect(service).to have_received(:get_purchase_subscriptionsv2).with("com.example.app", "tillbell-check")
      expect(service).not_to receive(:acknowledge_purchase_subscription)
    end

    it "checks each expected plan exists with an active base plan" do
      allow(service).to receive(:get_monetization_subscription).and_return(subscription)

      check, results = run(online: true, plans: [ "premium:monthly", { product_id: "premium", base_plan_id: "monthly" } ])

      expect(check).to be_ok
      expect(service).to have_received(:get_monetization_subscription).with("com.example.app", "premium").twice
      expect(status_of(results, "Subscription premium")).to eq(:ok)
    end

    it "fails on an inactive base plan or an unknown one, and names the ones that exist" do
      allow(service).to receive(:get_monetization_subscription).with(anything, "draft").and_return(subscription(plans: { "monthly" => "DRAFT" }))
      allow(service).to receive(:get_monetization_subscription).with(anything, "yearly").and_return(subscription(plans: { "annual" => "ACTIVE" }))

      _, results = run(online: true, plans: [ "draft:monthly", "yearly:yearly" ])

      expect(detail_of(results, "draft")).to include("DRAFT")
      expect(detail_of(results, "yearly")).to include("base plan", "annual")
    end

    it "accepts a plan without a base plan id as long as one base plan is active" do
      allow(service).to receive(:get_monetization_subscription).and_return(subscription(plans: { "draft" => "DRAFT", "live" => "ACTIVE" }))

      expect(run(online: true, plans: [ "premium" ]).first).to be_ok
    end

    it "lists what the Play Console has when no plan is given, across pages" do
      first = Google::Apis::AndroidpublisherV3::ListSubscriptionsResponse.new(subscriptions: [ subscription ], next_page_token: "page-2")
      second = Google::Apis::AndroidpublisherV3::ListSubscriptionsResponse.new(
        subscriptions: [ subscription(product_id: "pro", plans: { "monthly" => "ACTIVE", "annual" => "DRAFT" }) ]
      )
      allow(service).to receive(:list_monetization_subscriptions).with("com.example.app", page_size: 1000, page_token: nil).and_return(first)
      allow(service).to receive(:list_monetization_subscriptions).with("com.example.app", page_size: 1000, page_token: "page-2").and_return(second)

      _, results = run(online: true)

      expect(detail_of(results, "Subscription pro")).to eq("monthly (active), annual (draft)")
      expect(status_of(results, "Subscription premium")).to eq(:ok)
    end

    it "warns when the Play Console has no subscription" do
      allow(service).to receive(:list_monetization_subscriptions).and_return(Google::Apis::AndroidpublisherV3::ListSubscriptionsResponse.new)

      expect(status_of(run(online: true).last, "Subscriptions in the Play Console")).to eq(:warn)
    end

    describe "when Google refuses" do
      def probe_fails_with(error)
        allow(service).to receive(:get_purchase_subscriptionsv2).and_raise(error)
        run(online: true, plans: [ "premium:monthly" ])
      end

      it "explains a 401 as missing permissions, not as a bad key" do
        _, results = probe_fails_with(Google::Apis::AuthorizationError.new("insufficient", status_code: 401))

        expect(detail_of(results, "Reading purchases")).to include("401", "View financial data", "up to a day")
        expect(detail_of(results, "Reading purchases")).not_to include("revoked")
      end

      it "explains a 403, which is also what a disabled API answers" do
        _, results = probe_fails_with(client_error(403))

        expect(detail_of(results, "Reading purchases")).to include("enable the Google Play Android Developer API", "Manage orders and subscriptions")
      end

      it "calls a revoked or deleted key what it is" do
        _, results = probe_fails_with(Signet::AuthorizationError.new("invalid_grant"))

        expect(detail_of(results, "Reading purchases")).to include("key refused", "new JSON key")
      end

      it "does not check the plans once purchases cannot be read" do
        expect(service).not_to receive(:get_monetization_subscription)

        probe_fails_with(client_error(403))
      end

      it "mentions the one more permission the product catalog may need" do
        allow(service).to receive(:get_monetization_subscription).and_raise(client_error(403))

        _, results = run(online: true, plans: [ "premium:monthly" ])

        expect(detail_of(results, "Subscription premium")).to include("View app information")
      end

      it "says a 404 on a product means a wrong package name or product" do
        allow(service).to receive(:get_monetization_subscription).and_raise(client_error(404))

        _, results = run(online: true, plans: [ "premium:monthly" ])

        expect(detail_of(results, "Subscription premium")).to include("wrong package name", "no such product")
      end

      it "reports any other failure without leaking a secret" do
        allow(service).to receive(:get_purchase_subscriptionsv2).and_raise(RuntimeError, "boom")

        _, results = run(online: true)

        expect(results.last.detail).to eq("RuntimeError: boom")
      end
    end

    it "says why Google was not asked when the configuration is incomplete" do
      google.service_account_json = nil
      expect(Tillbell::GooglePlay).not_to receive(:service)

      check, results = run(online: true)

      expect(check).not_to be_ok
      expect(status_of(results, "Google was not asked")).to eq(:warn)
    end
  end
end
