# Signs App Store payloads the way Apple does (ES256, with an x5c chain carrying Apple's
# extensions), with a test certificate chain that specs trust instead of Apple Root CA - G3.
module AppStoreHelpers
  BUNDLE_ID = "com.example.app".freeze

  # A root, an intermediate and a leaf certificate, and the leaf's key.
  Chain = Data.define(:root, :intermediate, :leaf, :leaf_key) do
    def certificates
      [ leaf, intermediate, root ]
    end
  end

  def self.certificate(name, key, issuer: nil, issuer_key: key, ca: false, oid: nil)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = SecureRandom.random_number(2**64)
    certificate.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
    certificate.issuer = issuer ? issuer.subject : certificate.subject
    certificate.public_key = key
    certificate.not_before = Time.now - 365 * 86_400
    certificate.not_after = Time.now + 365 * 86_400
    extensions = OpenSSL::X509::ExtensionFactory.new(issuer || certificate, certificate)
    certificate.add_extension(extensions.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
    certificate.add_extension(extensions.create_extension("keyUsage", ca ? "keyCertSign,cRLSign" : "digitalSignature", true))
    certificate.add_extension(OpenSSL::X509::Extension.new(oid, OpenSSL::ASN1::Null.new(nil).to_der)) if oid
    certificate.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
  end

  def self.chain(leaf_oid: Tillbell::AppStore::LEAF_OID, intermediate_oid: Tillbell::AppStore::INTERMEDIATE_OID)
    root_key, intermediate_key, leaf_key = Array.new(3) { OpenSSL::PKey::EC.generate("prime256v1") }
    root = certificate("Test Root", root_key, ca: true)
    intermediate = certificate("Test Intermediate", intermediate_key, issuer: root, issuer_key: root_key, ca: true, oid: intermediate_oid)
    leaf = certificate("Test Leaf", leaf_key, issuer: intermediate, issuer_key: intermediate_key, oid: leaf_oid)
    Chain.new(root: root, intermediate: intermediate, leaf: leaf, leaf_key: leaf_key)
  end

  TRUSTED_CHAIN = chain

  # +payload+ signed as Apple signs a JWS.
  def app_store_jws(payload, chain: TRUSTED_CHAIN)
    x5c = chain.certificates.map { |certificate| Base64.strict_encode64(certificate.to_der) }
    JWT.encode(payload, chain.leaf_key, "ES256", { x5c: x5c })
  end

  # The decoded payload of an App Store Server Notification (version 2), with the signed
  # transaction and renewal information inside.
  def app_store_notification(type, transaction:, renewal_info: nil, subtype: nil, bundle_id: BUNDLE_ID)
    {
      "notificationType" => type, "subtype" => subtype, "notificationUUID" => SecureRandom.uuid, "version" => "2.0",
      "signedDate" => apple_time(Time.current),
      "data" => {
        "bundleId" => bundle_id, "environment" => "Sandbox",
        "signedTransactionInfo" => app_store_jws(transaction),
        "signedRenewalInfo" => renewal_info && app_store_jws(renewal_info)
      }.compact
    }.compact
  end
end

RSpec.configure do |config|
  config.include AppStoreHelpers

  config.before do
    Tillbell::AppStore.root_certificates = [ AppStoreHelpers::TRUSTED_CHAIN.root ]
    Tillbell.apple.bundle_id = AppStoreHelpers::BUNDLE_ID
  end

  config.after do
    Tillbell::AppStore.root_certificates = nil
    Tillbell.apple.bundle_id = nil
  end
end
