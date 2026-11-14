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
end
