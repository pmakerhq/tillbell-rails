# Tillbell: Google Play and App Store subscriptions stored as Pay subscriptions.
# See https://github.com/pmakerhq/tillbell-rails#configuration
#
# The two values below come from Google: the README's "Google Play setup" has the credentials
# template and every click. Once they are in your credentials, check everything with
#   bin/rails tillbell:check          (ONLINE=1 also asks Google)
Tillbell.configure do |config|
  # Application id of the Android app.
  config.google.package_name = "com.example.app"

  # JSON key of a Google Cloud service account invited in the Play Console with the
  # "View financial data" and "Manage orders and subscriptions" permissions.
  config.google.service_account_json = Rails.application.credentials.dig(:tillbell, :google_service_account)

  # Service account the Pub/Sub push subscription authenticates with.
  config.google.pubsub_service_account_email = Rails.application.credentials.dig(:tillbell, :pubsub_service_account_email)

  # Audience of the Pub/Sub OIDC token, if it is not the notification endpoint URL.
  # config.google.pubsub_audience = "https://example.com/tillbell/notifications/google_play"

  # Bundle identifier of the iOS app, to accept App Store purchases (tillbell-ios). Set the
  # App Store Server Notifications URL to https://<your host>/tillbell/notifications/app_store
  # (version 2) in App Store Connect.
  # config.apple.bundle_id = "com.example.app"

  # Who is buying. Evaluated in the controller and the view of the paywall.
  # config.current_owner = -> { current_user }

  # Controller the purchase endpoint inherits from (authentication, CSRF, ...).
  # config.parent_controller = "ApplicationController"

  # Pay subscription name of a Google Play product, as used by `subscribed?(name:)`.
  # config.subscription_name = ->(product_id:, base_plan_id:) { Pay.default_product_name }

  # React to subscription changes. Each block receives the Pay::GooglePlay::Subscription.
  # config.on(:subscription_created) { |subscription| }
  # config.on(:subscription_updated) { |subscription| }
  # config.on(:subscription_canceled) { |subscription| }
  # config.on(:subscription_expired) { |subscription| }
  # config.on(:subscription_revoked) { |subscription| }
  # config.on(:purchase_rejected) { |details| } # a token posted by another account
end
