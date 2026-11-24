module Pay
  module AppStore
    # A payment the App Store took for a subscription, stored as a Pay charge: the first
    # purchase and every renewal are each a transaction, and each paid transaction is one charge.
    # Revenue reports that sum Pay charges then count the App Store next to Stripe.
    #
    # [processor_id] The +transactionId+, unique per payment.
    # [amount] The price the customer paid, in the smallest unit of +currency+ (cents), like
    #          Stripe charges: the App Store Connect price of the storefront, before Apple's
    #          commission, tax included where the storefront's prices include it (not in the
    #          United States or Canada, for example).
    # [currency] Lowercase ISO 4217 code of the storefront's currency ("eur").
    # [amount_refunded] The part of +amount+ Apple refunded, zero when a refund is reversed.
    # [created_at] When Apple charged the customer (+purchaseDate+).
    # [object] The signed transaction payload, for debugging.
    #
    # +data+ holds +environment+ ("Production", "Sandbox" or "Xcode"), +product_id+ and
    # +signed_date_ms+, when Apple signed the payload the charge was last updated from.
    #
    # Sandbox purchases are recorded too, as their subscriptions are: leave them out of revenue
    # with +sandbox?+, or in SQL with the +sandbox+ scope.
    class Charge < Pay::Charge
      store_accessor :data, :environment, :product_id, :signed_date_ms

      # Environments of purchases that cost nothing: TestFlight and App Review (Sandbox) and
      # Xcode StoreKit Testing.
      SANDBOX_ENVIRONMENTS = %w[Sandbox Xcode].freeze

      # The +revocationPercentage+ of a full refund: Apple gives percentages in thousandths.
      FULL_REVOCATION = 100_000

      # Revocations that give money back. A Family Sharing or group assignment revocation only
      # removes someone's access to a purchase another person paid for.
      REFUNDS = %w[REFUND_FULL REFUND_PRORATED].freeze

      # Charges of sandbox and Xcode purchases. +where.not+ on this scope leaves them out.
      scope :sandbox, -> { where("#{environment_sql} IN (?)", SANDBOX_ENVIRONMENTS) }

      class << self
        # SQL reading +data.environment+ as text, in the JSON syntax of the database: PostgreSQL,
        # SQLite, or MySQL and MariaDB (Pay supports all of them).
        def environment_sql
          with_connection do |connection|
            column = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name("data")}"
            case connection.adapter_name
            when /postg/i then "#{column}->>'environment'"
            when /sqlite/i then "json_extract(#{column}, '$.environment')"
            else "JSON_UNQUOTE(JSON_EXTRACT(#{column}, '$.environment'))"
            end
          end
        end

        # Saves the charge of a verified transaction (see Tillbell::AppStore.verify_transaction!)
        # of +subscription+, or updates its refund. Idempotent: a transaction is one charge,
        # however many times a restore, a notification or a backfill brings it, and a payload
        # signed before the one the charge was last updated from changes nothing, so a late or
        # replayed purchase never undoes a refund. Call it holding the subscription's row lock,
        # as Pay::AppStore::Subscription.sync does, so two callers never insert the same
        # transaction at once.
        #
        # Returns the charge, or nil when nothing was paid (a free trial), for a Family Sharing
        # transaction (only the buyer's own transaction is a payment), for a transaction of
        # another customer (several accounts can share an Apple Account, so one
        # +originalTransactionId+ can be on two customers' subscriptions), and when the
        # transaction has no price in a currency Pay knows.
        #
        # ponytail: the prorated refund Apple gives on an upgrade is not in the transaction data,
        # so the upgraded transaction keeps its full amount.
        def sync(transaction, subscription)
          return if transaction["inAppOwnershipType"] == "FAMILY_SHARED"
          return unless transaction["appAccountToken"].to_s.downcase == subscription.customer.processor_id

          # Without a price, or a free trial: nothing was paid.
          return if transaction["price"].to_i.zero?

          amount = amount_from(transaction)
          if amount.nil?
            Rails.logger.warn "[Tillbell] No charge for App Store transaction #{transaction["transactionId"]}: unknown currency #{transaction["currency"].inspect}"
            return
          end
          return if amount.zero?

          charge = find_or_initialize_by(customer_id: subscription.customer_id, processor_id: transaction["transactionId"].to_s)
          return charge if transaction["signedDate"].to_i < charge.signed_date_ms.to_i

          charge.update!(
            subscription: subscription,
            amount: amount,
            currency: transaction["currency"].downcase,
            amount_refunded: refunded(amount, transaction),
            created_at: Tillbell::AppStore.time(transaction["purchaseDate"]),
            environment: transaction["environment"],
            product_id: transaction["productId"],
            signed_date_ms: transaction["signedDate"].to_i,
            object: transaction
          )
          charge
        end

        private
          # The price in the smallest unit of its currency, nil for a currency Pay does not know.
          # Apple sends it in thousandths of the currency unit (14990 for 14.99 euros), whatever
          # the currency's own decimals.
          def amount_from(transaction)
            subunits = Pay::Currency.all.dig(transaction["currency"].to_s.downcase, "subunit_to_unit")
            (BigDecimal(transaction["price"].to_s) * subunits / 1000).round.to_i if subunits
          end

          # A refund without +revocationType+ is a full one, as before Apple added prorated
          # refunds, except on a transaction the customer upgraded from: its revocation is the
          # upgrade, not a refund. A reversed refund removes the revocation fields.
          def refunded(amount, transaction)
            return 0 if transaction["revocationDate"].nil?

            type = transaction["revocationType"]
            return 0 if type.present? ? !REFUNDS.include?(type) : transaction["isUpgraded"] == true

            percentage = transaction["revocationPercentage"] || FULL_REVOCATION
            (BigDecimal(amount) * percentage / FULL_REVOCATION).round.to_i
          end
      end

      # True for a sandbox or Xcode purchase, which costs nothing: leave it out of revenue.
      def sandbox?
        SANDBOX_ENVIRONMENTS.include?(environment)
      end

      # Only Apple refunds App Store purchases: send the customer to
      # +Tillbell::AppStore::REFUND_URL+. Apple then notifies the refund, which updates the charge.
      def refund!(*, **)
        raise Tillbell::Error, "Only Apple refunds App Store purchases; the customer asks at #{Tillbell::AppStore::REFUND_URL}"
      end

      # Pay re-reads a charge from its processor by id; App Store charges are only updated from
      # Apple's signed transactions (see +sync+), which a transaction id alone cannot fetch.
      def sync!(**)
        raise Tillbell::Error, "App Store charges are updated from Apple's notifications, or with tillbell:app_store:backfill_charges"
      end
    end
  end
end
