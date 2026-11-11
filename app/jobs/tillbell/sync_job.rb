module Tillbell
  # Reads a Google Play purchase and updates its Pay subscription in the background.
  #
  # Enqueued for every real-time developer notification, and when Google could not be
  # reached while recording a purchase. Google outages and rate limits are retried;
  # a token Google does not know is dropped.
  class SyncJob < ActiveJob::Base
    queue_as :default

    retry_on(*GooglePlay::TRANSIENT_ERRORS, wait: :polynomially_longer, attempts: 10)
    discard_on(Google::Apis::ClientError) do |_job, error|
      # Anything but an invalid token is a configuration problem worth failing loudly for.
      raise error unless GooglePlay.invalid_token?(error)
    end

    # +revoked+ is true when the notification reports a refund.
    def perform(purchase_token, revoked: false)
      Pay::GooglePlay::Subscription.sync(purchase_token, revoked: revoked)
    end
  end
end
