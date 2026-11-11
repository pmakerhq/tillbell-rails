module Pay
  module GooglePlay
    # The Pay customer behind every Google Play purchase of an owner.
    #
    # Its +processor_id+ is a random UUID sent to Google as +obfuscatedAccountId+ when a
    # purchase starts. Google returns it with every purchase, which is how Tillbell knows
    # which owner a purchase token belongs to. It never contains an e-mail or a database
    # id, and the same value can later be reused as an App Store +appAccountToken+.
    #
    # The customer is added next to the owner's other Pay customers (Stripe, ...) without
    # becoming their default payment processor.
    class Customer < Pay::Customer
      has_many :subscriptions, dependent: :destroy, class_name: "Pay::GooglePlay::Subscription"

      before_validation :generate_processor_id, on: :create

      # Returns the Google Play customer of +owner+, creating it on first use.
      # +owner+ is any model declaring +pay_customer+.
      def self.for(owner)
        owner.add_payment_processor(:google_play)
      end

      # Google Play customers exist only in this database.
      def api_record
        self
      end

      def update_api_record(**)
        self
      end

      # Store purchases always start in the native app, never on the server.
      def subscribe(**)
        raise Tillbell::Error, "Google Play subscriptions are purchased in the Android app, through the Tillbell paywall"
      end

      def charge(*)
        raise Tillbell::Error, "Google Play does not support server-side charges"
      end

      def add_payment_method(*, **)
        raise Tillbell::Error, "Google Play manages payment methods in the Play Store"
      end

      private
        def generate_processor_id
          self.processor ||= "google_play"
          self.processor_id ||= SecureRandom.uuid
        end
    end
  end
end
