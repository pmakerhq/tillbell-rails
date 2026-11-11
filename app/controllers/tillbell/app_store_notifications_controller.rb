module Tillbell
  # Receives App Store Server Notifications (version 2), the URL set as the "Production
  # Server URL" (and "Sandbox Server URL") in App Store Connect.
  #
  # The endpoint is public, so every notification must carry Apple's signature for this app;
  # anything else gets a 401. Verified notifications are stored and processed by Pay
  # (+Pay::Webhook+ and +Pay::Webhooks::ProcessJob+), like Google Play notifications, and
  # answered with a 200 straight away. A non-2xx answer would make Apple send it again.
  class AppStoreNotificationsController < Pay::Webhooks::BaseController
    private
      def verified_event
        AppStore.verify_notification!(params[:signedPayload])
      end

      # "DID_RENEW" becomes "did_renew".
      def event_type(notification)
        notification["notificationType"].to_s.downcase
      end

      def queue?(notification)
        Rails.logger.info "[Tillbell] App Store notification #{notification["notificationType"]}" \
          "#{" subtype=#{notification["subtype"]}" if notification["subtype"]}"
        notification.dig("data", "signedTransactionInfo").present?
      end

      # Pay derives the processor from the controller name; this one is not named after it.
      def processor
        "app_store"
      end

      def invalid_signature
        head :unauthorized
      end
  end
end
