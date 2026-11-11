require "google/apis/androidpublisher_v3"
require "googleauth"
require "erb"

module Tillbell
  # Thin client over the Google Play Developer API (Android Publisher v3).
  #
  # Every method returns plain hashes with snake_case symbol keys, so the rest of the
  # gem (and its specs) never deal with the Google client classes.
  module GooglePlay
    SCOPE = "https://www.googleapis.com/auth/androidpublisher".freeze

    # Errors worth retrying later: rate limiting, Google server errors and network failures.
    TRANSIENT_ERRORS = [ Google::Apis::RateLimitError, Google::Apis::ServerError, Google::Apis::TransmissionError ].freeze

    # Everything a call to Google can raise besides a bug: API errors, and the errors of the
    # request for an access token (a revoked key, Google's token server failing).
    API_ERRORS = [ Google::Apis::Error, Signet::AuthorizationError, Signet::RemoteServerError, Signet::UnexpectedStatusError ].freeze

    # HTTP statuses Google answers for a purchase token it does not know (invented,
    # malformed, or expired for more than 60 days). Other client errors, such as a 403
    # for a service account without access to the Play Console, are configuration
    # problems and must not be mistaken for an invalid purchase.
    INVALID_TOKEN_STATUSES = [ 400, 404, 410 ].freeze

    # +notificationType+ of a subscription notification sent when a purchase is refunded.
    # See https://developer.android.com/google/play/billing/rtdn-reference
    SUBSCRIPTION_REVOKED = 12

    class << self
      # Handles a real-time developer notification (the decoded Pub/Sub message).
      #
      # A notification is a trigger, never a source of truth: it only says which purchase
      # changed, and the job reads the actual state from Google. This keeps duplicated or
      # out-of-order notifications harmless.
      def handle_notification(notification)
        if (subscription = notification["subscriptionNotification"])
          revoked = subscription["notificationType"] == SUBSCRIPTION_REVOKED
          Tillbell::SyncJob.perform_later(subscription["purchaseToken"], revoked: revoked)
        elsif (voided = notification["voidedPurchaseNotification"])
          Tillbell::SyncJob.perform_later(voided["purchaseToken"], revoked: true)
        end
      end

      # Fetches the current state of a subscription purchase (+purchases.subscriptionsv2.get+).
      def subscription(purchase_token)
        service.get_purchase_subscriptionsv2(package_name, purchase_token).to_h
      end

      # Acknowledges a subscription purchase. Google refunds purchases that are not
      # acknowledged within three days.
      def acknowledge(product_id, purchase_token)
        service.acknowledge_purchase_subscription(package_name, product_id, purchase_token)
      end

      # Stops the renewal of a subscription. The customer keeps access until the end of
      # the current period.
      def cancel(product_id, purchase_token)
        service.cancel_purchase_subscription(package_name, product_id, purchase_token)
      end

      # Verifies the OIDC token Pub/Sub sends with a push request and returns its claims.
      # Raises +Tillbell::Error+ unless Google signed it for +audience+ on behalf of the
      # configured service account.
      def verify_pubsub_token!(token, audience:)
        claims = Google::Auth::IDTokens.verify_oidc(token.to_s, aud: audience)
        expected = Tillbell.google.pubsub_service_account_email
        unless expected.present? && claims["email"] == expected && claims["email_verified"]
          raise Error, "Pub/Sub token was not issued for the configured service account"
        end

        claims
      rescue Google::Auth::IDTokens::VerificationError => error
        raise Error, error.message
      end

      # True when +error+ means that the purchase token itself is invalid.
      def invalid_token?(error)
        error.is_a?(Google::Apis::ClientError) && INVALID_TOKEN_STATUSES.include?(error.status_code)
      end

      # The +obfuscatedAccountId+ the purchase was made with, i.e. the +processor_id+ of
      # the Pay::GooglePlay::Customer it belongs to.
      def account_id(subscription_purchase)
        subscription_purchase.dig(:external_account_identifiers, :obfuscated_external_account_id)
      end

      # The Play Store page where a customer manages (updates payment, cancels, resubscribes)
      # a subscription: the page of +product_id+, or the list of all subscriptions without
      # it. Same page as the +manage+ message of the native component, for web pages and
      # emails.
      def manage_url(product_id = nil)
        page = "https://play.google.com/store/account/subscriptions"
        return page if product_id.blank?

        "#{page}?sku=#{ERB::Util.url_encode(product_id)}&package=#{ERB::Util.url_encode(package_name)}"
      end

      # The Play Store page of the app itself (+config.google.package_name+), for a "Get it on
      # Google Play" link on the website.
      def store_url
        "https://play.google.com/store/apps/details?id=#{ERB::Util.url_encode(package_name)}"
      end

      # The Android package name Google Play knows the app by, from +config.google.package_name+.
      # Raises +Tillbell::Error+ when it is not set.
      def package_name
        Tillbell.google.package_name.presence || raise(Error, "Tillbell.google.package_name is not set")
      end

      # Memoized API client. Clear it with +reset!+ after changing credentials.
      def service
        @service ||= Google::Apis::AndroidpublisherV3::AndroidPublisherService.new.tap do |service|
          service.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(service_account_json), scope: SCOPE
          )
        end
      end

      # Forgets the memoized client so the next call builds it from the current credentials.
      def reset!
        @service = nil
      end

      private
        # Accepts the key as a JSON string or as a hash (e.g. from Rails credentials).
        def service_account_json
          json = Tillbell.google.service_account_json
          raise Error, "Tillbell.google.service_account_json is not set" if json.blank?

          json.is_a?(String) ? json : json.to_json
        end
    end
  end
end
