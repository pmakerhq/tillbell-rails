RSpec.describe Tillbell::AppStore do
  let(:transaction) { app_store_transaction(account_id: SecureRandom.uuid) }

  describe ".verify_transaction!" do
    it "returns the payload of a transaction Apple signed for this app" do
      expect(described_class.verify_transaction!(app_store_jws(transaction))).to eq(transaction)
    end

    describe "Xcode StoreKit Testing" do
      let(:xcode) { JWT.encode(app_store_transaction(account_id: SecureRandom.uuid, environment: "Xcode"), OpenSSL::PKey::EC.generate("prime256v1"), "ES256") }

      after { Tillbell.apple.allow_xcode_transactions = nil }

      it "accepts an Xcode transaction without Apple's signature only when allowed, and never elsewhere than in development and test" do
        expect { described_class.verify_transaction!(xcode) }.to raise_error(Tillbell::Error)

        Tillbell.apple.allow_xcode_transactions = true
        expect(described_class.verify_transaction!(xcode)).to include("environment" => "Xcode")

        allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
        expect { described_class.verify_transaction!(xcode) }.to raise_error(Tillbell::Error)
      end

      it "still checks the app and the product type, and leaves other unsigned transactions refused" do
        Tillbell.apple.allow_xcode_transactions = true
        other_app = JWT.encode(app_store_transaction(account_id: "a", environment: "Xcode", bundle_id: "com.other"), nil, "none")
        forged = JWT.encode(app_store_transaction(account_id: "a", environment: "Production"), nil, "none")

        expect { described_class.verify_transaction!(other_app) }.to raise_error(Tillbell::Error, /another app/)
        expect { described_class.verify_transaction!(forged) }.to raise_error(Tillbell::Error)
      end
    end

    it "refuses a payload changed after signing" do
      header, _payload, signature = app_store_jws(transaction).split(".")
      forged = Base64.urlsafe_encode64(transaction.merge("productId" => "premium.yearly").to_json, padding: false)

      expect { described_class.verify_transaction!([ header, forged, signature ].join(".")) }.to raise_error(Tillbell::Error, /signature/i)
    end

    it "refuses a chain that does not end at Apple's root" do
      jws = app_store_jws(transaction, chain: AppStoreHelpers.chain)

      expect { described_class.verify_transaction!(jws) }.to raise_error(Tillbell::Error, /root/)
    end

    it "refuses the real Apple root with a chain it did not issue" do
      described_class.root_certificates = nil
      chain = AppStoreHelpers.chain
      forged = AppStoreHelpers::Chain.new(root: Tillbell::AppStore::ROOT_CERTIFICATE, intermediate: chain.intermediate, leaf: chain.leaf, leaf_key: chain.leaf_key)

      expect { described_class.verify_transaction!(app_store_jws(transaction, chain: forged)) }.to raise_error(Tillbell::Error, /Untrusted/)
    end

    it "refuses certificates without Apple's App Store extensions" do
      jws = app_store_jws(transaction, chain: AppStoreHelpers.chain(leaf_oid: nil))
      described_class.root_certificates = [ JWT.decode(jws, nil, false).last["x5c"].last.then { |der| OpenSSL::X509::Certificate.new(Base64.strict_decode64(der)) } ]

      expect { described_class.verify_transaction!(jws) }.to raise_error(Tillbell::Error, /not issued/)
    end

    it "refuses a transaction of another app" do
      jws = app_store_jws(transaction.merge("bundleId" => "com.other.app"))

      expect { described_class.verify_transaction!(jws) }.to raise_error(Tillbell::Error, /another app/)
    end

    it "refuses a purchase that is not an auto-renewable subscription" do
      jws = app_store_jws(transaction.merge("type" => "Consumable"))

      expect { described_class.verify_transaction!(jws) }.to raise_error(Tillbell::Error, /auto-renewable/)
    end

    it "refuses garbage" do
      expect { described_class.verify_transaction!("not.a.jws") }.to raise_error(Tillbell::Error)
    end

    it "requires the bundle id" do
      Tillbell.apple.bundle_id = nil

      expect { described_class.verify_transaction!(app_store_jws(transaction)) }.to raise_error(Tillbell::Error, /bundle_id/)
    end
  end

  describe ".jws?" do
    it "tells an App Store transaction from a Google Play purchase token" do
      expect(described_class.jws?(app_store_jws(transaction))).to be(true)
      expect(described_class.jws?("ajdkfhakjsd.AO-J1OyX7zZ1fRk2gE5z")).to be(false)
      expect(described_class.jws?("a.b.c")).to be(false)
      expect(described_class.jws?(nil)).to be(false)
    end
  end

  describe ".verify_notification!" do
    it "returns a notification Apple signed for this app" do
      notification = app_store_notification("DID_RENEW", transaction: transaction)

      expect(described_class.verify_notification!(app_store_jws(notification))).to eq(notification)
    end

    it "refuses a notification of another app" do
      notification = app_store_notification("DID_RENEW", transaction: transaction, bundle_id: "com.other.app")

      expect { described_class.verify_notification!(app_store_jws(notification)) }.to raise_error(Tillbell::Error, /another app/)
    end
  end

  describe "App Store Server API" do
    let(:user) { User.create!(email: "ada@example.com") }
    let(:account_id) { Pay::GooglePlay::Customer.for(user).processor_id }
    let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
    let(:requests) { [] }

    def paid(**options)
      app_store_jws(app_store_transaction(account_id: account_id, price: "14.99", currency: "EUR", **options))
    end

    def http_response(klass, code, body)
      klass.new("1.1", code, "").tap do |response|
        response.instance_variable_set(:@body, body)
        response.instance_variable_set(:@read, true)
      end
    end

    # Answers each request with the next page and records the request.
    def stub_history(*pages)
      allow(Net::HTTP).to receive(:start) do |host, *, &block|
        http = instance_double(Net::HTTP)
        allow(http).to receive(:request) do |request|
          requests << [ host, request ]
          http_response(Net::HTTPOK, "200", pages.shift.to_json)
        end
        block.call(http)
      end
    end

    before do
      Tillbell.apple.issuer_id = "57246542-96fe-1a63-e053-0824d011072a"
      Tillbell.apple.key_id = "2X9R4HXF34"
      Tillbell.apple.private_key = key.to_pem
    end

    after { Tillbell.apple.issuer_id = Tillbell.apple.key_id = Tillbell.apple.private_key = nil }

    it "backfills the charges of a subscription from its transaction history, page by page, once" do
      subscription = create_app_store_subscription(user)
      other_subscription = app_store_jws(app_store_transaction(account_id: account_id, original_transaction_id: "9", transaction_id: "9", price: "1", currency: "EUR"))
      pages = [
        { "signedTransactions" => [ paid(purchased_at: 2.months.ago), other_subscription ], "hasMore" => true, "revision" => "r1" },
        { "signedTransactions" => [ paid(transaction_id: "2000000000000002", purchased_at: 1.month.ago, revoked_at: 1.day.ago) ], "hasMore" => false }
      ]
      stub_history(*pages.deep_dup)

      expect(described_class.backfill_charges(subscription)).to eq(2)
      expect(Pay::AppStore::Charge.order(:created_at).pluck(:processor_id, :amount, :amount_refunded))
        .to eq([ [ "2000000000000001", 1499, 0 ], [ "2000000000000002", 1499, 1499 ] ])

      host, request = requests.first
      expect(host).to eq("api.storekit.apple.com")
      expect(request.path).to eq("/inApps/v2/history/2000000000000001?productType=AUTO_RENEWABLE&sort=ASCENDING")
      expect(requests.last.last.path).to end_with("&revision=r1")
      token = request["Authorization"].delete_prefix("Bearer ")
      payload, header = JWT.decode(token, key, true, algorithm: "ES256")
      expect(header).to include("kid" => "2X9R4HXF34", "typ" => "JWT")
      expect(payload).to include("iss" => "57246542-96fe-1a63-e053-0824d011072a", "aud" => "appstoreconnect-v1", "bid" => AppStoreHelpers::BUNDLE_ID)

      stub_history(*pages)
      expect { described_class.backfill_charges(subscription) }.not_to change(Pay::AppStore::Charge, :count)
    end

    it "asks the sandbox for sandbox subscriptions and never asks for Xcode ones" do
      stub_history({ "signedTransactions" => [], "hasMore" => false })

      described_class.backfill_charges(create_app_store_subscription(user, environment: "Sandbox"))
      expect(described_class.backfill_charges(create_app_store_subscription(user, original_transaction_id: "3", environment: "Xcode"))).to eq(0)
      expect(requests.map(&:first)).to eq([ "api.storekit-sandbox.apple.com" ])
    end

    it "says which setting is missing and what Apple answered" do
      Tillbell.apple.key_id = nil
      expect { described_class.transaction_history("1").first }.to raise_error(Tillbell::Error, /Tillbell.apple.key_id/)

      Tillbell.apple.key_id = "2X9R4HXF34"
      allow(Net::HTTP).to receive(:start).and_return(http_response(Net::HTTPUnauthorized, "401", '{"errorCode":4010000}'))
      expect { described_class.transaction_history("1").first }.to raise_error(Tillbell::Error, /answered 401/)
    end
  end
end
