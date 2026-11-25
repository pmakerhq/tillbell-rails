module Tillbell
  # Reports a paid Stripe invoice (+kind+ "invoice") or a refunded charge (+kind+ "refund") to
  # Google Play, outside the webhook request: Google may be slow or down, and a refund may
  # arrive before its payment is reported. See Tillbell::StripeExternalOffers.
  class StripeExternalTransactionJob < ActiveJob::Base
    queue_as :default

    # Reporting is due within 24 hours, so every failure is retried for as long: Google or Stripe
    # down, a refund waiting for its payment, an invoice without a country. Until its row exists,
    # an invoice is only retried here; Tillbell::ExternalTransactionsJob takes over once it does.
    # Past that, the payment or refund is not reported: +external_transaction_failed+ says so.
    retry_on StandardError, wait: 30.minutes, attempts: 48 do |job, error|
      kind, id = job.arguments
      Rails.error.report(error, handled: true, context: { kind: kind, id: id })
      Tillbell.instrument(:external_transaction_failed, { kind: kind, id: id, error: error })
    end

    # Reads the invoice or charge from Stripe, so the job always works on its current state.
    def perform(kind, id)
      case kind
      when "invoice" then StripeExternalOffers.report_invoice(::Stripe::Invoice.retrieve(id))
      when "refund" then StripeExternalOffers.refund_charge(::Stripe::Charge.retrieve(id))
      else raise ArgumentError, "unknown kind #{kind.inspect}"
      end
    end
  end
end
