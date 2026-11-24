module Pay
  module AppStore
    # A payment the App Store took for a subscription, stored as a Pay charge: the first
    # purchase and every renewal are each a transaction, and each paid transaction is one charge.
    # Revenue reports that sum Pay charges then count the App Store next to Stripe.
    #
    # [processor_id] The +transactionId+, unique per payment.
    # [amount] What the customer paid, tax included and before Apple's commission, in the
    #          smallest unit of +currency+ (cents), like Stripe charges.
    # [currency] Lowercase ISO 4217 code of the storefront's currency ("eur").
    # [amount_refunded] The part of +amount+ Apple refunded, zero when a refund is reversed.
    # [created_at] When Apple charged the customer (+purchaseDate+).
    # [object] The signed transaction payload, for debugging.
    #
    # +data+ holds +environment+ ("Production", "Sandbox" or "Xcode") and +product_id+.
    class Charge < Pay::Charge
      store_accessor :data, :environment, :product_id

      # The +revocationPercentage+ of a full refund: Apple gives percentages in thousandths.
      FULL_REVOCATION = 100_000

      # Revocations that give money back. A Family Sharing or group assignment revocation only
      # removes someone's access to a purchase another person paid for.
      REFUNDS = %w[REFUND_FULL REFUND_PRORATED].freeze

      class << self
        # Saves the charge of a verified transaction (see Tillbell::AppStore.verify_transaction!)
        # of +subscription+, or updates its refund. Idempotent: a transaction is one charge,
        # however many times a restore, a notification or a backfill brings it. Call it holding
        # the subscription's row lock, as Pay::AppStore::Subscription.sync does, so two callers
        # never insert the same transaction at once.
        #
        # Returns the charge, or nil when nothing was paid (a free trial), for a Family Sharing
        # transaction (only the buyer's own transaction is a payment), and when the transaction
        # has no price in a currency Pay knows.
        #
        # ponytail: the prorated refund Apple gives on an upgrade is not in the transaction data,
        # so the upgraded transaction keeps its full amount.
        def sync(transaction, subscription)
          return if transaction["inAppOwnershipType"] == "FAMILY_SHARED"

          amount = amount_from(transaction)
          if amount.nil?
            Rails.logger.warn "[Tillbell] No charge for App Store transaction #{transaction["transactionId"]}: no price in a known currency"
            return
          end
          return if amount.zero?

          charge = find_or_initialize_by(customer_id: subscription.customer_id, processor_id: transaction["transactionId"].to_s)
          charge.update!(
            subscription: subscription,
            amount: amount,
            currency: transaction["currency"].downcase,
            amount_refunded: refunded(amount, transaction),
            created_at: Tillbell::AppStore.time(transaction["purchaseDate"]),
            environment: transaction["environment"],
            product_id: transaction["productId"],
            object: transaction
          )
          charge
        end

        private
          # The price in the smallest unit of its currency, nil without a price or for a currency
          # Pay does not know. Apple sends it in thousandths of the currency unit (14990 for
          # 14.99 euros), whatever the currency's own decimals.
          def amount_from(transaction)
            return if transaction["price"].nil?

            subunits = Pay::Currency.all.dig(transaction["currency"].to_s.downcase, "subunit_to_unit")
            (BigDecimal(transaction["price"].to_s) * subunits / 1000).round.to_i if subunits
          end

          # A refund without +revocationPercentage+ is a full one, as before Apple added
          # prorated refunds. A reversed refund removes the revocation fields.
          def refunded(amount, transaction)
            return 0 if transaction["revocationDate"].nil?
            return 0 if transaction["revocationType"].present? && !REFUNDS.include?(transaction["revocationType"])

            percentage = transaction["revocationPercentage"] || FULL_REVOCATION
            (BigDecimal(amount) * percentage / FULL_REVOCATION).round.to_i
          end
      end

      # True for a sandbox or Xcode purchase, which costs nothing: leave it out of revenue.
      def sandbox?
        environment == "Sandbox" || environment == "Xcode"
      end
    end
  end
end
