module Tillbell
  # Receives Google Play real-time developer notifications from a Cloud Pub/Sub push
  # subscription.
  #
  # The endpoint is public, so every request must carry an OIDC token signed by Google
  # for the configured Pub/Sub service account; anything else gets a 401. Verified
  # notifications are stored and processed by Pay (+Pay::Webhook+ and
  # +Pay::Webhooks::ProcessJob+), exactly like Stripe webhooks, and answered with a 200
  # straight away. A non-2xx answer would make Pub/Sub deliver the message again.
  class NotificationsController < Pay::Webhooks::BaseController
    # Notification kinds, as keys of the decoded Pub/Sub message.
    # See https://developer.android.com/google/play/billing/rtdn-reference
    KINDS = %w[subscriptionNotification voidedPurchaseNotification testNotification oneTimeProductNotification].freeze

    # +productType+ of a voided purchase that is a subscription (2 is a one-time product).
    VOIDED_SUBSCRIPTION = 1

    private
      # Verifies the Pub/Sub token and returns the decoded notification.
      def verified_event
        GooglePlay.verify_pubsub_token!(request.authorization.to_s.delete_prefix("Bearer "), audience: audience)

        # Pub/Sub wraps the notification in a base64 encoded "data" field.
        JSON.parse(params.dig(:message, :data).to_s.unpack1("m"))
      rescue JSON::ParserError
        raise Tillbell::Error, "Malformed Pub/Sub message"
      end

      def event_type(notification)
        KINDS.find { |kind| notification.key?(kind) }&.underscore
      end

      # Only subscription changes of this app are processed; everything else is
      # acknowledged so Pub/Sub stops sending it.
      def queue?(notification)
        kind = event_type(notification)
        log(notification, kind)

        return false unless notification["packageName"] == GooglePlay.package_name

        case kind
        when "subscription_notification" then true
        when "voided_purchase_notification" then notification.dig("voidedPurchaseNotification", "productType") == VOIDED_SUBSCRIPTION
        else false
        end
      end

      # Pay derives the processor from the controller name; this one is not named after it.
      def processor
        "google_play"
      end

      # Pub/Sub signs its requests for the push endpoint URL unless configured otherwise.
      def audience
        Tillbell.google.pubsub_audience.presence || "#{request.base_url}#{request.path}"
      end

      def invalid_signature
        head :unauthorized
      end

      # Logs the kind of notification and a shortened token, never the full token.
      def log(notification, kind)
        token = notification.dig("subscriptionNotification", "purchaseToken") ||
          notification.dig("voidedPurchaseNotification", "purchaseToken")
        type = notification.dig("subscriptionNotification", "notificationType")
        Rails.logger.info "[Tillbell] Google Play notification #{kind || "unknown"}" \
          "#{" type=#{type}" if type}#{" token=#{Tillbell.redact(token)}" if token}"
      end
  end
end
