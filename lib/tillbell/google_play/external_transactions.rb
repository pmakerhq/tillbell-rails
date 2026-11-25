module Tillbell
  module GooglePlay
    # Reports payments made through Google Play's external offers program (EEA) with the
    # External Transactions API of the Play Developer API. The program requires every payment
    # made outside Google Play to be reported within 24 hours: the first payment of a
    # subscription with the token the app got from Google Play, each renewal linked to that
    # first transaction, and every refund. See
    # https://support.google.com/googleplay/android-developer/answer/14372887
    #
    # Nothing here is guessed: amounts, tax region and link type are arguments. It uses the
    # service account of +config.google.service_account_json+ and +config.google.package_name+.
    # Tillbell::ExternalTransaction keeps what was reported and calls it.
    module ExternalTransactions
      # The request and response classes of the Google client.
      Types = Google::Apis::AndroidpublisherV3

      class << self
        # Reports a subscription payment (+externaltransactions.createexternaltransaction+).
        #
        # [external_transaction_id] Your id for this payment, sent again on a retry: Google
        #                           answers 409 for an id it already has, which counts as success.
        # [pre_tax_micros], [tax_micros] Amounts paid, in micros of +currency+ (ISO 4217).
        # [region_code] Two-letter country code of the customer's tax address.
        # [transaction_time] When the customer paid.
        # [link_type] How the app sent the customer out, e.g. +LINK_TO_DIGITAL_CONTENT_OFFER+.
        # [token] The external transaction token from Google Play, for the first payment.
        # [initial_external_transaction_id] The id of the first payment, for a renewal.
        def report(external_transaction_id:, pre_tax_micros:, tax_micros:, currency:, region_code:, transaction_time:,
                   link_type:, token: nil, initial_external_transaction_id: nil)
          if token.present? == initial_external_transaction_id.present?
            raise ArgumentError, "pass the token of a first payment, or the initial_external_transaction_id of a renewal"
          end

          transaction = Types::ExternalTransaction.new(
            original_pre_tax_amount: price(pre_tax_micros, currency),
            original_tax_amount: price(tax_micros, currency),
            transaction_time: transaction_time.utc.iso8601,
            user_tax_address: Types::ExternalTransactionAddress.new(region_code: region_code.to_s.upcase),
            recurring_transaction: Types::RecurringExternalTransaction.new(
              external_transaction_token: token.presence,
              initial_external_transaction_id: initial_external_transaction_id.presence,
              external_subscription: Types::ExternalSubscription.new(subscription_type: "RECURRING")
            ),
            external_offer_details: Types::ExternalOfferDetails.new(link_type: link_type)
          )
          already_received do
            GooglePlay.service.createexternaltransaction_externaltransaction(
              parent, transaction, external_transaction_id: external_transaction_id
            )
          end
        end

        # Reports a refund of a reported payment (+externaltransactions.refundexternaltransaction+):
        # a full refund without +pre_tax_micros+, otherwise a partial refund of that pre-tax
        # amount, identified by +refund_id+ so that a retry does not refund twice.
        def refund(external_transaction_id:, refund_time:, pre_tax_micros: nil, currency: nil, refund_id: nil)
          request = Types::RefundExternalTransactionRequest.new(refund_time: refund_time.utc.iso8601)
          if pre_tax_micros
            raise ArgumentError, "a partial refund needs a currency and a refund_id" if currency.blank? || refund_id.blank?

            request.partial_refund = Types::PartialRefund.new(refund_id: refund_id, refund_pre_tax_amount: price(pre_tax_micros, currency))
          else
            request.full_refund = Types::FullRefund.new
          end
          name = "#{parent}/externalTransactions/#{external_transaction_id}"
          already_received { GooglePlay.service.refundexternaltransaction_externaltransaction(name, request) }
        rescue Google::Apis::ClientError
          # A full refund has no id of its own: when a retry follows a success whose answer was
          # lost, Google refuses it. The transaction says whether the refund is already done.
          raise if pre_tax_micros || GooglePlay.service.getexternaltransaction_externaltransaction(name).transaction_state != "TRANSACTION_REFUNDED"
        end

        # The pre-tax amount of a reported payment once its refunds are deducted, in micros, as
        # Google has it (+externaltransactions.getexternaltransaction+).
        def current_pre_tax_micros(external_transaction_id)
          GooglePlay.service.getexternaltransaction_externaltransaction("#{parent}/externalTransactions/#{external_transaction_id}")
                    .current_pre_tax_amount.price_micros.to_i
        end

        private
          def parent = "applications/#{GooglePlay.package_name}"

          def price(micros, currency)
            Types::Price.new(price_micros: micros.to_i.to_s, currency: currency.to_s.upcase)
          end

          # Google answers 409 for a transaction or refund it already has, typically a retry
          # after a success whose answer was lost: the report is done.
          def already_received
            yield
          rescue Google::Apis::ClientError => error
            raise unless error.status_code == 409
          end
      end
    end
  end
end
