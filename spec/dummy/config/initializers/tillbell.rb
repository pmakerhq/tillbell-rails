Tillbell.configure do |config|
  config.google.package_name = "com.example.app"
  config.google.service_account_json = { type: "service_account" }
  config.google.pubsub_service_account_email = "pubsub@example.iam.gserviceaccount.com"
end
