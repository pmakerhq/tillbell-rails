module Tillbell
  # Safety net of the external offers reporting, to run every hour (e.g. in
  # +config/recurring.yml+): reports again every payment Google does not have yet (a Google
  # outage, a key fixed after it expired), and emits +external_transaction_overdue+ once for
  # each payment still unreported after Tillbell::ExternalTransaction::OVERDUE_AFTER, before
  # the 24-hour deadline of the program.
  class ExternalTransactionsJob < ActiveJob::Base
    queue_as :default

    # One failing payment must not keep the others from being reported: its error is kept in
    # +last_error+ and reported to +Rails.error+.
    def perform
      ExternalTransaction.unreported.find_each do |transaction|
        transaction.report!
      rescue StandardError => error
        Rails.error.report(error, handled: true, context: { external_transaction_id: transaction.external_transaction_id })
      end

      ExternalTransaction.overdue.where(overdue_at: nil).find_each do |transaction|
        transaction.update!(overdue_at: Time.current)
        Tillbell.instrument(:external_transaction_overdue, transaction)
      end
    end
  end
end
