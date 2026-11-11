module Tillbell
  # Records a Google Play or App Store purchase made in the native app.
  #
  # The paywall posts the purchase token here as soon as the purchase sheet succeeds, so
  # access is granted without waiting for a notification. The token is never trusted:
  # Tillbell reads a Google Play purchase from Google, verifies Apple's signature of an App
  # Store transaction (the token the iOS app sends), and checks that the purchase was made
  # with the account id of the signed-in owner.
  #
  # Inherits from +Tillbell.parent_controller+ to run the host app's authentication and
  # CSRF protection.
  #
  # Responds with JSON whose +status+ is one of:
  #
  # [verified] The purchase is recorded; +active+ tells whether it grants access yet
  #            (a pending purchase does not).
  # [verifying] Google could not be reached; the purchase is verified in the background.
  # [rejected] The purchase belongs to another account.
  # [invalid] Google does not know this purchase token, or Apple did not sign this
  #           transaction for this app.
  class PurchasesController < Tillbell.parent_controller.constantize
    def create
      owner = instance_exec(&Tillbell.current_owner)
      return head :unauthorized if owner.nil?

      purchase_token = params.expect(:purchase_token)
      return record_app_store_transaction(owner, purchase_token) if AppStore.jws?(purchase_token)

      purchase = GooglePlay.subscription(purchase_token)

      if GooglePlay.account_id(purchase) == Pay::GooglePlay::Customer.for(owner).processor_id
        subscription = Pay::GooglePlay::Subscription.sync(purchase_token, object: purchase)
        render json: { status: "verified", active: subscription.active?, subscription_status: subscription.status }
      else
        Tillbell.instrument(:purchase_rejected, owner: owner, purchase_token: Tillbell.redact(purchase_token))
        render json: { status: "rejected" }, status: :forbidden
      end
    rescue *GooglePlay::TRANSIENT_ERRORS
      # The job only trusts Google's answer, so it can safely finish without the owner check.
      SyncJob.perform_later(purchase_token)
      render json: { status: "verifying" }, status: :accepted
    rescue Google::Apis::ClientError => error
      raise unless GooglePlay.invalid_token?(error)

      render json: { status: "invalid" }, status: :unprocessable_content
    end

    private
      # The signature is checked on the server, without calling Apple, so there is no
      # "verifying" answer for the App Store.
      def record_app_store_transaction(owner, jws)
        transaction = AppStore.verify_transaction!(jws)

        if transaction["appAccountToken"].to_s.downcase == Pay::GooglePlay::Customer.for(owner).processor_id
          subscription = Pay::AppStore::Subscription.sync(transaction)
          render json: { status: "verified", active: subscription.active?, subscription_status: subscription.status }
        else
          Tillbell.instrument(:purchase_rejected, owner: owner, purchase_token: Tillbell.redact(transaction["originalTransactionId"]))
          render json: { status: "rejected" }, status: :forbidden
        end
      rescue Tillbell::Error => error
        Rails.logger.info "[Tillbell] Refusing an App Store transaction: #{error.message}"
        render json: { status: "invalid" }, status: :unprocessable_content
      end
  end
end
