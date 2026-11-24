require "base64"
require "erb"
require "json"
require "jwt"
require "net/http"
require "openssl"

module Tillbell
  # Verifies what the App Store signs: the transactions StoreKit 2 hands to the iOS app, and the
  # App Store Server Notifications (version 2). Both are JWS (compact JSON Web Signatures)
  # signed with ES256 by a certificate chain that ends at Apple Root CA - G3, given in the
  # +x5c+ header. Verifying needs no key and no call to Apple, so the purchase endpoint answers
  # at once and never has to retry later.
  #
  # Every method returns the decoded payload as a hash with Apple's camelCase string keys.
  #
  # Only the charge backfill calls Apple, through the App Store Server API: see
  # +transaction_history+ and +config.apple.issuer_id+.
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

    # App Store Server API hosts, by the +environment+ of the transactions they hold. Xcode
    # StoreKit Testing transactions never reach Apple's servers.
    API_HOSTS = {
      "Production" => "https://api.storekit.apple.com",
      "Sandbox" => "https://api.storekit-sandbox.apple.com"
    }.freeze

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

      # Yields each auto-renewable subscription transaction of the customer who made
      # +transaction_id+ (any of their transaction ids), verified like a purchase, from the
      # App Store Server API ("Get Transaction History"). Refunded transactions are included,
      # with their revocation fields. Returns an enumerator without a block.
      #
      # Needs an In-App Purchase key: +config.apple.issuer_id+, +key_id+ and +private_key+.
      # Raises +Tillbell::Error+ when Apple refuses the request.
      def transaction_history(transaction_id, environment: "Production")
        return enum_for(:transaction_history, transaction_id, environment: environment) unless block_given?

        revision = nil
        loop do
          query = { productType: "AUTO_RENEWABLE", sort: "ASCENDING", revision: revision }.compact
          response = api_get(environment, "/inApps/v2/history/#{ERB::Util.url_encode(transaction_id)}", query)
          Array(response["signedTransactions"]).each { |jws| yield verify_transaction!(jws) }
          break unless response["hasMore"] && response["revision"].present?

          revision = response["revision"]
        end
      end

      # Saves the charge of every paid transaction of +subscription+ (a
      # Pay::AppStore::Subscription), read from Apple: the charges of purchases made before
      # Tillbell recorded charges, or of notifications that never arrived. Idempotent, so it can
      # run again. Returns the number of paid transactions synced, unchanged ones included.
      def backfill_charges(subscription)
        environment = subscription.environment.presence || "Production"
        return 0 unless API_HOSTS.key?(environment)

        transaction_history(subscription.processor_id, environment: environment).count do |transaction|
          # The history holds all the customer's purchases in the app, other subscriptions too.
          next false unless transaction["originalTransactionId"] == subscription.processor_id

          # The same row lock as notifications take (see Pay::AppStore::Subscription.sync), on a
          # fresh copy so the caller's instance is neither reloaded nor required to be clean.
          Pay::AppStore::Subscription.transaction do
            Pay::AppStore::Charge.sync(transaction, Pay::AppStore::Subscription.lock.find(subscription.id)).present?
          end
        end
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
        # GETs +path+ from the App Store Server API of +environment+ and returns the parsed body.
        # Network failures and unreadable answers raise +Tillbell::Error+ too, so a caller going
        # through many subscriptions can report one and move on.
        #
        # ponytail: no retry on 429 (rate limited); the backfill reports it and can run again.
        def api_get(environment, path, query)
          uri = URI(API_HOSTS.fetch(environment) { raise Error, "No App Store Server API for #{environment.inspect} transactions" } + path)
          uri.query = URI.encode_www_form(query) if query.any?
          request = Net::HTTP::Get.new(uri, "Authorization" => "Bearer #{api_token}")
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
          # Apple's error bodies only hold an errorCode and an errorMessage.
          raise Error, "App Store Server API answered #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
          raise Error, "App Store Server API request failed: #{error.class}: #{error.message}"
        end

        # A JSON Web Token for one App Store Server API request, signed with the In-App Purchase
        # key. Apple refuses tokens valid for more than an hour; five minutes cover a request.
        def api_token
          apple = Tillbell.apple
          missing = %i[issuer_id key_id private_key].select { |setting| apple[setting].blank? }
          raise Error, "Set Tillbell.apple.#{missing.join(", ")} to call the App Store Server API" if missing.any?

          now = Time.now.to_i
          payload = { iss: apple.issuer_id, iat: now, exp: now + 300, aud: "appstoreconnect-v1", bid: bundle_id }
          JWT.encode(payload, OpenSSL::PKey::EC.new(apple.private_key), "ES256", { kid: apple.key_id, typ: "JWT" })
        rescue OpenSSL::PKey::PKeyError
          raise Error, "Tillbell.apple.private_key is not the content of an In-App Purchase key (.p8)"
        end

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
