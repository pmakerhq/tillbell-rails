require "base64"
require "json"
require "jwt"
require "openssl"

module Tillbell
  # Verifies what the App Store signs: the transactions StoreKit 2 hands to the iOS app, and the
  # App Store Server Notifications (version 2). Both are JWS (compact JSON Web Signatures)
  # signed with ES256 by a certificate chain that ends at Apple Root CA - G3, given in the
  # +x5c+ header. Verifying needs no key and no call to Apple, so the purchase endpoint answers
  # at once and never has to retry later.
  #
  # Every method returns the decoded payload as a hash with Apple's camelCase string keys.
  module AppStore
    # Apple Root CA - G3, from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
    # SHA-256 fingerprint 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79,
    # valid until 2039.
    ROOT_CERTIFICATE = OpenSSL::X509::Certificate.new(<<~PEM).freeze
      -----BEGIN CERTIFICATE-----
      MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
      QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
      IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
      MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
      b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
      aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
      AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
      TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
      IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
      MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
      MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
      at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
      6BgD56KyKA==
      -----END CERTIFICATE-----
    PEM

    # Extensions Apple puts on the certificates that sign App Store data: the leaf (Mac App
    # Store and iTunes Store receipt signing) and the intermediate (Apple Worldwide Developer
    # Relations). A chain without them was not issued for this purpose.
    LEAF_OID = "1.2.840.113635.100.6.11.1".freeze
    INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1".freeze

    # +productType+ of an auto-renewable subscription transaction.
    AUTO_RENEWABLE = "Auto-Renewable Subscription".freeze

    # The page where a customer manages (cancels, changes, resubscribes) their App Store
    # subscriptions. Same page as the +manage+ message of the iOS component.
    MANAGE_URL = "https://apps.apple.com/account/subscriptions".freeze

    # The page where a customer asks Apple for a refund: only Apple refunds App Store
    # purchases, the app cannot. Apple then notifies the refund, which revokes the subscription.
    REFUND_URL = "https://reportaproblem.apple.com".freeze

    class << self
      # The certificates a chain must end at. Only specs change it.
      attr_writer :root_certificates

      def root_certificates
        @root_certificates || [ ROOT_CERTIFICATE ]
      end

      # True when +token+ looks like a JWS from the App Store rather than a Google Play purchase
      # token. It says nothing about its validity: see +verify_transaction!+.
      def jws?(token)
        parts = token.to_s.split(".")
        parts.size == 3 && JSON.parse(Base64.urlsafe_decode64(parts.first)).key?("x5c")
      rescue ArgumentError, JSON::ParserError, NoMethodError
        false
      end

      # Verifies a signed transaction (+VerificationResult.jwsRepresentation+ in StoreKit 2)
      # and returns its payload. Raises +Tillbell::Error+ unless Apple signed it, for this app
      # (+config.apple.bundle_id+), and it is an auto-renewable subscription.
      #
      # With +config.apple.allow_xcode_transactions+, in development and test, a transaction
      # Xcode signed for StoreKit Testing is accepted without checking its signature, as
      # Apple's own server libraries do for the Xcode environment. Notifications never come from
      # Xcode and are always fully verified.
      def verify_transaction!(jws)
        transaction = xcode_transaction(jws) || decode!(jws)
        raise Error, "The transaction belongs to another app (#{transaction["bundleId"]})" unless transaction["bundleId"] == bundle_id
        raise Error, "The transaction is not an auto-renewable subscription" unless transaction["type"] == AUTO_RENEWABLE

        transaction
      end

      # Verifies the +signedPayload+ of an App Store Server Notification and returns its
      # payload. Raises +Tillbell::Error+ unless Apple signed it for this app.
      def verify_notification!(signed_payload)
        notification = decode!(signed_payload)
        # Most notifications describe one transaction under "data"; a summary of a mass
        # extension and an external purchase notification put the app under their own key.
        app = %w[data summary externalPurchaseToken].filter_map { |key| notification.dig(key, "bundleId") }.first
        raise Error, "The notification belongs to another app" unless app == bundle_id

        notification
      end

      # Handles a verified notification: re-reads the transaction and renewal information it
      # carries and updates the subscription. Notifications without a transaction (a test
      # notification, a summary of a mass extension) and those about other in-app purchases of
      # the app change nothing.
      def handle_notification(notification)
        data = notification["data"] || {}
        return if data["signedTransactionInfo"].blank?

        transaction = decode!(data["signedTransactionInfo"])
        return unless transaction["type"] == AUTO_RENEWABLE

        transaction = verify_transaction!(data["signedTransactionInfo"])
        renewal_info = data["signedRenewalInfo"].presence&.then { |jws| decode!(jws) }
        Pay::AppStore::Subscription.sync(transaction, renewal_info)
      end

      # The bundle identifier of the iOS app, from +config.apple.bundle_id+. Raises
      # +Tillbell::Error+ when it is not set.
      def bundle_id
        Tillbell.apple.bundle_id.presence || raise(Error, "Tillbell.apple.bundle_id is not set")
      end

      # Verifies the signature and certificate chain of any App Store JWS and returns its
      # payload, without looking at what it contains.
      #
      # ponytail: no revocation check (OCSP) of the chain; Apple's own library makes it optional.
      def decode!(jws)
        header = JSON.parse(Base64.urlsafe_decode64(jws.to_s.split(".").first.to_s))
        raise Error, "Unexpected JWS algorithm #{header["alg"].inspect}" unless header["alg"] == "ES256"

        leaf, intermediate, root = certificates = Array(header["x5c"]).map { |der| OpenSSL::X509::Certificate.new(Base64.strict_decode64(der)) }
        raise Error, "The JWS does not carry a three-certificate chain" unless certificates.size == 3
        raise Error, "The certificate chain does not end at Apple's root" unless root_certificates.any? { |trusted| trusted.to_der == root.to_der }
        raise Error, "The certificates were not issued to sign App Store data" unless extension?(leaf, LEAF_OID) && extension?(intermediate, INTERMEDIATE_OID)

        payload, = JWT.decode(jws, leaf.public_key, true, algorithm: "ES256")
        verify_chain!(leaf, intermediate, root, at: signed_at(payload))
        payload
      # NoMethodError: a header that is not a JSON object, or an x5c that does not hold strings,
      # posted by anyone to the public notification endpoint.
      rescue JWT::DecodeError, OpenSSL::X509::CertificateError, ArgumentError, JSON::ParserError, TypeError, NoMethodError => error
        raise Error, "Invalid App Store signature: #{error.message}"
      end

      # Milliseconds since the epoch, as Apple sends every date, to a time.
      def time(milliseconds)
        Time.zone.at(milliseconds / 1000.0) if milliseconds.present?
      end

      private
        # The payload of +jws+ when it is an Xcode StoreKit Testing transaction that the
        # configuration allows, otherwise nil. Never in production or staging: without Apple's
        # signature, anyone could forge one.
        def xcode_transaction(jws)
          return unless Tillbell.apple.allow_xcode_transactions && Rails.env.local?

          payload, = JWT.decode(jws, nil, false)
          payload if payload["environment"] == "Xcode"
        rescue JWT::DecodeError
          nil
        end

        # The chain must be valid when Apple signed the data, not only today: a transaction
        # signed a year ago, restored now, may carry a leaf certificate that has since expired.
        def verify_chain!(leaf, intermediate, root, at:)
          store = OpenSSL::X509::Store.new
          store.add_cert(root)
          store.time = at
          raise Error, "Untrusted certificate chain: #{store.error_string}" unless store.verify(leaf, [ intermediate ])
        end

        def signed_at(payload)
          time(payload["signedDate"]) || Time.current
        end

        def extension?(certificate, oid)
          certificate.extensions.any? { |extension| extension.oid == oid }
        end
    end
  end
end
