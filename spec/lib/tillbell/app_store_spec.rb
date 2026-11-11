RSpec.describe Tillbell::AppStore do
  let(:transaction) { app_store_transaction(account_id: SecureRandom.uuid) }

  describe ".verify_transaction!" do
    it "returns the payload of a transaction Apple signed for this app" do
      expect(described_class.verify_transaction!(app_store_jws(transaction))).to eq(transaction)
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
