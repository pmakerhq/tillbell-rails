module Tillbell
  # A payment made through Google Play's external offers program, and what was reported of it
  # to Google (see Tillbell::GooglePlay::ExternalTransactions). Rows are created by the Stripe
  # integration (Tillbell::StripeExternalOffers), one per paid invoice, before Google is called:
  # the external transaction id is fixed from then on, so every retry sends the same one.
  #
  # Install the table with +bin/rails tillbell:install:migrations db:migrate+.
  class ExternalTransaction < ActiveRecord::Base
    # A payment must be reported within this delay, or the app breaches the program.
    REPORTING_DEADLINE = 24.hours

    # How old an unreported payment is when +external_transaction_overdue+ fires, leaving time
    # to fix the cause before the deadline.
    OVERDUE_AFTER = 20.hours

    # Raised by +refund!+ for a payment not reported yet: Google cannot refund it, so the
    # refund is retried once the payment is reported instead of being lost.
    class NotReported < Error; end

    # Payments Google does not have yet.
    scope :unreported, -> { where(reported_at: nil) }
    # Unreported payments made more than OVERDUE_AFTER ago. The deadline runs from the payment,
    # not from the row, which can be created late (an invoice first missing its country).
    scope :overdue, -> { unreported.where(transaction_time: ..OVERDUE_AFTER.ago) }

    # True for the first payment of a subscription, which Google links to the app's token.
    def initial? = initial_external_transaction_id.blank?

    # True once Google has the payment.
    def reported? = reported_at.present?

    # Reports the payment to Google, unless it already was. The error, if any, is kept in
    # +last_error+ and raised again for the caller to retry.
    def report!
      return if reported?

      GooglePlay::ExternalTransactions.report(
        external_transaction_id: external_transaction_id, pre_tax_micros: pre_tax_micros, tax_micros: tax_micros,
        currency: currency, region_code: region_code, transaction_time: transaction_time, link_type: link_type,
        token: (external_transaction_token if initial?), initial_external_transaction_id: initial_external_transaction_id
      )
      update!(reported_at: Time.current, last_error: nil)
    rescue *GooglePlay::API_ERRORS => error
      update_column(:last_error, "#{error.class}: #{error.message}".truncate(1000)) if persisted?
      raise
    end

    # Reports a refund, given the gross amount refunded so far in micros (+total_refunded_micros+,
    # tax included, as payment processors count it). Only the part not reported yet is sent, so
    # each refund event can call it with its running total. +full+ is true when the whole payment
    # is refunded: a first refund that is full is reported as a full refund, any other one as a
    # partial refund of its pre-tax share.
    #
    # ponytail: a full refund that follows a partial one is reported as a partial refund of the
    # rest; switch to a full refund if Google ever requires it.
    def refund!(total_refunded_micros, full:)
      raise NotReported, "external transaction #{external_transaction_id} is not reported yet" unless reported?

      # ponytail: the row stays locked during Google's call, so two refunds of one payment queue
      # up instead of both sending the same delta; refunds are rare enough for that.
      with_lock do
        delta = total_refunded_micros - refunded_micros
        next unless delta.positive?

        if full && refunded_micros.zero?
          GooglePlay::ExternalTransactions.refund(external_transaction_id: external_transaction_id, refund_time: Time.current)
          update!(refunded_micros: total_refunded_micros, refunded_pre_tax_micros: pre_tax_micros)
        else
          share = pre_tax_share(delta)
          begin
            GooglePlay::ExternalTransactions.refund(
              external_transaction_id: external_transaction_id, refund_time: Time.current, currency: currency,
              pre_tax_micros: share,
              # Deterministic, so a retry of the same refund is recognized by Google.
              refund_id: "#{external_transaction_id}-refund-#{total_refunded_micros}"
            )
          rescue Google::Apis::ClientError
            # Google may refuse a refund id it already has rather than answer 409, typically on a
            # retry after a success whose answer was lost. The refund is done when the payment's
            # current pre-tax amount already went down by it.
            remaining = pre_tax_micros - refunded_pre_tax_micros - share
            raise unless GooglePlay::ExternalTransactions.current_pre_tax_micros(external_transaction_id) <= remaining
          end
          update!(refunded_micros: total_refunded_micros, refunded_pre_tax_micros: refunded_pre_tax_micros + share)
        end
      end
    end

    private
      # The pre-tax part of a gross amount, in the payment's own pre-tax/tax proportion.
      def pre_tax_share(gross_micros)
        total = pre_tax_micros + tax_micros
        total.zero? ? 0 : gross_micros * pre_tax_micros / total
      end
  end
end
