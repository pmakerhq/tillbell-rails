module Pay
  module AppStore
    # The Pay customer behind every App Store purchase of an owner.
    #
    # Its +processor_id+ is the same UUID as the owner's Pay::GooglePlay::Customer: the paywall
    # sends one +obfuscatedAccountId+ to both apps, and the iOS app passes it to StoreKit as the
    # +appAccountToken+. Apple returns it in every signed transaction, which is how Tillbell
    # knows which owner a transaction belongs to.
    class Customer < Pay::Customer
      has_many :subscriptions, dependent: :destroy, class_name: "Pay::AppStore::Subscription"

      # Returns the App Store customer of +owner+, creating it on first use.
      def self.for(owner)
        owner.add_payment_processor(:app_store, processor_id: Pay::GooglePlay::Customer.for(owner).processor_id)
      end

      # The App Store customer whose account id is +app_account_token+, or nil when no owner
      # has it. Created on first use for an owner who only had a Google Play customer.
      def self.for_account_id(app_account_token)
        account_id = app_account_token.to_s.downcase
        return if account_id.blank?

        find_by(processor_id: account_id) || Pay::GooglePlay::Customer.find_by(processor_id: account_id)&.then { |customer| self.for(customer.owner) }
      end

      # App Store customers exist only in this database.
      def api_record
        self
      end

      def update_api_record(**)
        self
      end

      # Store purchases always start in the native app, never on the server.
      def subscribe(**)
        raise Tillbell::Error, "App Store subscriptions are purchased in the iOS app, through the Tillbell paywall"
      end

      def charge(*)
        raise Tillbell::Error, "The App Store does not support server-side charges"
      end

      def add_payment_method(*, **)
        raise Tillbell::Error, "The App Store manages payment methods in the customer's Apple Account"
      end
    end
  end
end
