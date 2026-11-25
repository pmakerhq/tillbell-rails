RSpec.describe Tillbell::ExternalTransaction do
  let(:api) { Tillbell::GooglePlay::ExternalTransactions }

  def create_transaction(**attributes)
    described_class.create!(
      stripe_invoice_id: "in_1", stripe_subscription_id: "sub_1", external_transaction_id: "in_1", external_transaction_token: "token",
      link_type: "LINK_TO_DIGITAL_CONTENT_OFFER", currency: "EUR", pre_tax_micros: 10_000_000, tax_micros: 2_000_000,
      region_code: "FR", transaction_time: Time.current, **attributes
    )
  end

  describe "#report!" do
    it "reports a first payment with its token once, and remembers it" do
      transaction = create_transaction
      expect(api).to receive(:report).once.with(hash_including(external_transaction_id: "in_1", token: "token", initial_external_transaction_id: nil))

      freeze_time do
        transaction.report!
        transaction.report!

        expect(transaction.reload.reported_at).to eq(Time.current)
      end
    end

    it "reports a renewal linked to its first payment, without the token" do
      transaction = create_transaction(initial_external_transaction_id: "in_0")
      expect(api).to receive(:report).with(hash_including(token: nil, initial_external_transaction_id: "in_0"))

      transaction.report!
    end

    it "keeps Google's error and raises it again for the caller to retry" do
      transaction = create_transaction
      allow(api).to receive(:report).and_raise(google_error(Google::Apis::ServerError, 503))

      expect { transaction.report! }.to raise_error(Google::Apis::ServerError)
      expect(transaction.reload).not_to be_reported
      expect(transaction.last_error).to include("Google::Apis::ServerError")
    end
  end

  describe "#refund!" do
    it "refuses a refund of a payment Google does not have yet" do
      expect { create_transaction.refund!(12_000_000, full: true) }.to raise_error(described_class::NotReported)
    end

    it "reports a first refund of the whole payment as a full refund" do
      transaction = create_transaction(reported_at: Time.current)
      expect(api).to receive(:refund).with(external_transaction_id: "in_1", refund_time: kind_of(Time))

      transaction.refund!(12_000_000, full: true)

      expect(transaction.reload.refunded_micros).to eq(12_000_000)
    end

    it "reports each partial refund as the pre-tax share of what was refunded since the last one" do
      transaction = create_transaction(reported_at: Time.current)
      expect(api).to receive(:refund).with(hash_including(pre_tax_micros: 2_500_000, refund_id: "in_1-refund-3000000", currency: "EUR")).ordered
      expect(api).to receive(:refund).with(hash_including(pre_tax_micros: 7_500_000, refund_id: "in_1-refund-12000000")).ordered

      transaction.refund!(3_000_000, full: false)
      transaction.refund!(12_000_000, full: true)
    end

    it "counts a refused partial refund as done when Google's amount already went down by it" do
      transaction = create_transaction(reported_at: Time.current, refunded_micros: 3_000_000, refunded_pre_tax_micros: 2_500_000)
      allow(api).to receive(:refund).and_raise(google_error(Google::Apis::ClientError, 400))
      allow(api).to receive(:current_pre_tax_micros).with("in_1").and_return(5_000_000)

      transaction.refund!(6_000_000, full: false)

      expect(transaction.reload).to have_attributes(refunded_micros: 6_000_000, refunded_pre_tax_micros: 5_000_000)
    end

    it "raises a refused partial refund that Google did not apply" do
      transaction = create_transaction(reported_at: Time.current)
      allow(api).to receive(:refund).and_raise(google_error(Google::Apis::ClientError, 400))
      allow(api).to receive(:current_pre_tax_micros).and_return(10_000_000)

      expect { transaction.refund!(3_000_000, full: false) }.to raise_error(Google::Apis::ClientError)
      expect(transaction.reload.refunded_micros).to eq(0)
    end

    it "reports nothing when nothing new was refunded (a webhook delivered twice)" do
      transaction = create_transaction(reported_at: Time.current, refunded_micros: 3_000_000)
      expect(api).not_to receive(:refund)

      transaction.refund!(3_000_000, full: false)
    end
  end

  it "finds the payments still unreported close to the 24-hour deadline, counted from the payment" do
    late = create_transaction(transaction_time: 21.hours.ago)
    create_transaction(stripe_invoice_id: "in_2", external_transaction_id: "in_2", transaction_time: 2.hours.ago, created_at: 30.hours.ago)
    create_transaction(stripe_invoice_id: "in_3", external_transaction_id: "in_3", transaction_time: 22.hours.ago, reported_at: 21.hours.ago)

    expect(described_class.overdue).to contain_exactly(late)
  end
end
