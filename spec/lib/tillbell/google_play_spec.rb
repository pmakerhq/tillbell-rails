RSpec.describe Tillbell::GooglePlay do
  describe ".verify_pubsub_token!" do
    let(:claims) { { "email" => "pubsub@example.iam.gserviceaccount.com", "email_verified" => true } }

    it "returns the claims of a token Google signed for the configured service account" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc).with("token", aud: "https://example.com").and_return(claims)

      expect(described_class.verify_pubsub_token!("token", audience: "https://example.com")).to eq(claims)
    end

    it "refuses an unverified e-mail" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_return(claims.merge("email_verified" => false))

      expect { described_class.verify_pubsub_token!("token", audience: "a") }.to raise_error(Tillbell::Error)
    end

    it "refuses every token when no service account is configured" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_return(claims)
      allow(Tillbell.google).to receive(:pubsub_service_account_email).and_return(nil)

      expect { described_class.verify_pubsub_token!("token", audience: "a") }.to raise_error(Tillbell::Error)
    end

    it "turns a verification failure into a Tillbell error" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_raise(Google::Auth::IDTokens::ExpiredTokenError, "expired")

      expect { described_class.verify_pubsub_token!("token", audience: "a") }.to raise_error(Tillbell::Error, "expired")
    end
  end

  describe ".subscription" do
    it "returns Google's answer as a hash" do
      service = instance_double(Google::Apis::AndroidpublisherV3::AndroidPublisherService)
      allow(described_class).to receive(:service).and_return(service)
      purchase = Google::Apis::AndroidpublisherV3::SubscriptionPurchaseV2.new(subscription_state: "SUBSCRIPTION_STATE_ACTIVE")
      allow(service).to receive(:get_purchase_subscriptionsv2).with("com.example.app", "token").and_return(purchase)

      expect(described_class.subscription("token")).to eq(subscription_state: "SUBSCRIPTION_STATE_ACTIVE")
    end
  end

  describe ".package_name" do
    it "raises a clear error when it is not configured" do
      allow(Tillbell.google).to receive(:package_name).and_return(nil)

      expect { described_class.package_name }.to raise_error(Tillbell::Error, /package_name/)
    end
  end

  describe ".manage_url" do
    before { allow(Tillbell).to receive(:google).and_return(ActiveSupport::OrderedOptions.new.merge(package_name: "com.example.app")) }

    it "points to the page of one subscription" do
      expect(described_class.manage_url("premium")).to eq("https://play.google.com/store/account/subscriptions?sku=premium&package=com.example.app")
    end

    it "encodes the product id" do
      expect(described_class.manage_url("a&b c")).to include("sku=a%26b%20c")
    end

    it "points to the list of subscriptions without a product" do
      expect(described_class.manage_url).to eq("https://play.google.com/store/account/subscriptions")
      expect(described_class.manage_url("")).to eq("https://play.google.com/store/account/subscriptions")
    end
  end

  describe ".store_url" do
    it "points to the Play Store page of the app" do
      allow(Tillbell).to receive(:google).and_return(ActiveSupport::OrderedOptions.new.merge(package_name: "com.example.app"))

      expect(described_class.store_url).to eq("https://play.google.com/store/apps/details?id=com.example.app")
    end
  end
end

RSpec.describe Tillbell do
  describe ".on" do
    it "refuses an unknown event" do
      expect { described_class.on(:subscription_exploded) { } }.to raise_error(ArgumentError, /unknown Tillbell event/)
    end

    it "delivers events to the block" do
      received = nil
      subscriber = described_class.on(:subscription_updated) { |payload| received = payload }

      described_class.instrument(:subscription_updated, :payload)

      expect(received).to eq(:payload)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  describe ".redact" do
    it "keeps only the start of a token" do
      expect(described_class.redact("abcdefghijklmnop")).to eq("abcdefgh...")
    end
  end
end
