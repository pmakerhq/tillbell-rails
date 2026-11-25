# How many times a payment was sent to Google and when last, to tell a payment that keeps
# failing from one that was never tried.
class AddReportAttemptsToTillbellExternalTransactions < ActiveRecord::Migration[8.0]
  def change
    change_table :tillbell_external_transactions, bulk: true do |t|
      t.integer :report_attempts, null: false, default: 0
      t.datetime :last_attempt_at
    end
  end
end
