# Payments made through Google Play's external offers program (EEA), reported to Google with
# the External Transactions API. One row per paid Stripe invoice: the unique invoice id keeps a
# payment from being reported twice, and the external transaction id is set before Google is
# called, so a retry sends the same id and Google's 409 ("already received") counts as success.
# Amounts are in micros, as Google takes them, so a partial refund can be derived from them.
class CreateTillbellExternalTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :tillbell_external_transactions do |t|
      t.string :stripe_invoice_id, null: false, index: { unique: true }
      # Finds the initial transaction of a subscription when it renews.
      t.string :stripe_subscription_id, null: false, index: true
      t.string :external_transaction_id, null: false, index: { unique: true }
      t.string :initial_external_transaction_id
      # The token the app got from Google Play, for the initial transaction only.
      t.string :external_transaction_token
      t.string :link_type, null: false
      t.string :currency, null: false
      t.bigint :pre_tax_micros, null: false
      t.bigint :tax_micros, null: false
      t.string :region_code, null: false
      t.datetime :transaction_time, null: false
      t.datetime :reported_at
      t.text :last_error
      t.bigint :refunded_micros, null: false, default: 0
      # When the external_transaction_overdue event was emitted, so it is emitted once.
      t.datetime :overdue_at
      t.timestamps

      t.index %i[reported_at created_at], name: "index_tillbell_external_transactions_unreported"
    end
  end
end
