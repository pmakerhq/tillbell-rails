RSpec.describe Tillbell::ExternalTransactionsJob do
  let(:api) { Tillbell::GooglePlay::ExternalTransactions }

  def create_transaction(id, **attributes)
    Tillbell::ExternalTransaction.create!(
      stripe_invoice_id: id, stripe_subscription_id: "sub_1", external_transaction_id: id, external_transaction_token: "token",
      link_type: "LINK_TO_DIGITAL_CONTENT_OFFER", currency: "EUR", pre_tax_micros: 1, tax_micros: 0, region_code: "FR",
      transaction_time: Time.current, **attributes
    )
  end

  it "reports every unreported payment again, even when one of them still fails" do
    failing = create_transaction("in_1")
    pending = create_transaction("in_2")
    create_transaction("in_3", reported_at: Time.current)
    allow(api).to receive(:report).with(hash_including(external_transaction_id: "in_1")).and_raise(google_error(Google::Apis::ServerError, 503))
    allow(api).to receive(:report).with(hash_including(external_transaction_id: "in_2"))
    allow(Rails.error).to receive(:report)

    described_class.perform_now

    expect(pending.reload).to be_reported
    expect(failing.reload).not_to be_reported
    expect(api).not_to have_received(:report).with(hash_including(external_transaction_id: "in_3"))
    expect(Rails.error).to have_received(:report).once
  end

  it "emits external_transaction_overdue once for a payment close to the deadline" do
    late = create_transaction("in_1", transaction_time: 21.hours.ago)
    allow(api).to receive(:report).and_raise(google_error(Google::Apis::ServerError, 503))
    allow(Rails.error).to receive(:report)
    overdue = []
    subscriber = Tillbell.on(:external_transaction_overdue) { |transaction| overdue << transaction }

    2.times { described_class.perform_now }

    expect(overdue).to eq([ late ])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
