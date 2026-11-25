module Tillbell
  # Reports to Google Play the Stripe payments of customers an Android app sent to a web
  # checkout through the external offers program. Opt in with +config.google.external_offers = true+,
  # then put the token the app got from Google Play (the +externalOffer+ bridge message) in the
  # metadata of the Stripe subscription, under +TOKEN_KEY+, when you create the Checkout Session:
  #
  #   Stripe::Checkout::Session.create(
  #     mode: "subscription", ...,
  #     subscription_data: { metadata: { Tillbell::StripeExternalOffers::TOKEN_KEY => token } }
  #   )
  #
  # Pay's +stripe.invoice.paid+ and +stripe.charge.refunded+ webhooks then enqueue
  # Tillbell::StripeExternalTransactionJob, which calls +report_invoice+ and +refund_charge+:
  # the first paid invoice is reported with the token, each renewal linked to it, and each
  # refund as the amount refunded since the last one.
  module StripeExternalOffers
    # Subscription metadata key holding the Google Play external transaction token.
    TOKEN_KEY = "play_external_transaction_token".freeze

    # Subscription metadata key holding the customer's two-letter country code, used when the
    # invoice has no customer address. Set it when Checkout does not collect an address.
    REGION_KEY = "play_external_transaction_region".freeze

    # How the app sends customers out: to an offer of digital content (the subscription).
    LINK_TYPE = "LINK_TO_DIGITAL_CONTENT_OFFER".freeze

    # Stripe counts these currencies in units, and these in thousandths, instead of hundredths:
    # https://docs.stripe.com/currencies#zero-decimal
    ZERO_DECIMAL_CURRENCIES = %w[bif clp djf gnf jpy kmf krw mga pyg rwf ugx vnd vuv xaf xof xpf].freeze
    THREE_DECIMAL_CURRENCIES = %w[bhd jod kwd omr tnd].freeze

    class << self
      # The Google Play token of the subscription +invoice+ (a +Stripe::Invoice+) pays for, or
      # nil when the subscription did not come from an external offer.
      def token(invoice)
        subscription_metadata(invoice)&.[](TOKEN_KEY).presence
      end

      # Records and reports a paid +invoice+ of a subscription that came from an external offer.
      # Idempotent. Reports nothing for a negative invoice (a proration credit is not a sale),
      # nor for a renewal whose first payment was never recorded (a subscription older than the
      # integration): that one emits +external_transaction_orphaned+ instead of sending Google a
      # transaction it cannot link.
      def report_invoice(invoice)
        token = token(invoice)
        return unless token

        transaction = ExternalTransaction.find_by(stripe_invoice_id: invoice.id) || record(invoice, token)
        transaction&.report!
        transaction
      end

      # Reports the refunds of +charge+ (a +Stripe::Charge+) not reported yet. Raises
      # Tillbell::ExternalTransaction::NotReported when the payment is not reported yet, so the
      # job retries rather than losing the refund. A refund of an orphaned renewal (see
      # +report_invoice+) is not reported either: Google never had the payment.
      def refund_charge(charge)
        invoice_id = invoice_id(charge)
        return unless invoice_id

        transaction = ExternalTransaction.find_by(stripe_invoice_id: invoice_id)
        if transaction.nil?
          invoice = ::Stripe::Invoice.retrieve(invoice_id)
          return unless token(invoice)
          return if orphaned?(invoice)

          raise ExternalTransaction::NotReported, "Stripe invoice #{invoice_id} is not recorded yet"
        end

        transaction.refund!(micros(charge.amount_refunded, charge.currency), full: charge.refunded)
      end

      # Converts a Stripe amount (in the currency's smallest unit) to micros.
      def micros(amount, currency)
        decimals = if ZERO_DECIMAL_CURRENCIES.include?(currency.to_s.downcase) then 0
        elsif THREE_DECIMAL_CURRENCIES.include?(currency.to_s.downcase) then 3
        else 2
        end
        amount.to_i * 10**(6 - decimals)
      end

      private
        def subscription_metadata(invoice)
          invoice.try(:parent).try(:subscription_details).try(:metadata)
        end

        def record(invoice, token)
          first = invoice.billing_reason == "subscription_create"
          return if !first && invoice.total.to_i.negative?

          subscription_id = invoice.parent.subscription_details.subscription
          unless first
            initial = initial_transaction(subscription_id)
            if initial.nil?
              Tillbell.instrument(:external_transaction_orphaned, { stripe_invoice_id: invoice.id, stripe_subscription_id: subscription_id })
              return
            end
          end

          region = invoice.try(:customer_address).try(:country).presence || subscription_metadata(invoice)[REGION_KEY].presence
          raise Error, "Stripe invoice #{invoice.id} has no customer country: set #{REGION_KEY} in the subscription metadata" unless region

          pre_tax = invoice.total_excluding_tax.to_i
          ExternalTransaction.create_or_find_by!(stripe_invoice_id: invoice.id) do |transaction|
            transaction.assign_attributes(
              stripe_subscription_id: subscription_id,
              external_transaction_id: invoice.id,
              initial_external_transaction_id: initial&.external_transaction_id,
              external_transaction_token: (token if first),
              link_type: LINK_TYPE,
              currency: invoice.currency.upcase,
              pre_tax_micros: micros(pre_tax, invoice.currency),
              tax_micros: micros(invoice.total.to_i - pre_tax, invoice.currency),
              region_code: region.upcase,
              transaction_time: Time.at(invoice.status_transitions.paid_at || invoice.created).utc
            )
          end
        end

        def initial_transaction(subscription_id)
          ExternalTransaction.where(stripe_subscription_id: subscription_id, initial_external_transaction_id: nil).first
        end

        # A renewal whose subscription has no recorded first payment, which is never reported.
        def orphaned?(invoice)
          invoice.billing_reason != "subscription_create" && initial_transaction(invoice.parent.subscription_details.subscription).nil?
        end

        # Stripe charges no longer name their invoice (API 2025-03-31 "basil"): the invoice is
        # found through the payment intent, as Pay does.
        def invoice_id(charge)
          return if charge.payment_intent.blank?

          ::Stripe::InvoicePayment.list(payment: { type: "payment_intent", payment_intent: charge.payment_intent }, limit: 1).data.first&.invoice
        end
    end
  end
end
