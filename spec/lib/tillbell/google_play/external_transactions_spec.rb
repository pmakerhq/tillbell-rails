RSpec.describe Tillbell::GooglePlay::ExternalTransactions do
  let(:service) { double("AndroidPublisherService") }
  let(:paid_at) { Time.utc(2026, 11, 20, 10, 30) }
  let(:payment) do
    { external_transaction_id: "in_1", pre_tax_micros: 4_160_000, tax_micros: 830_000, currency: "eur", region_code: "fr",
      transaction_time: paid_at, link_type: "LINK_TO_DIGITAL_CONTENT_OFFER" }
  end

  before do
    allow(Tillbell::GooglePlay).to receive(:service).and_return(service)
    allow(Tillbell.google).to receive(:package_name).and_return("com.example.app")
  end

  describe ".report" do
    it "reports a first payment with the app's token" do
      expect(service).to receive(:createexternaltransaction_externaltransaction) do |parent, transaction, external_transaction_id:|
        expect(parent).to eq("applications/com.example.app")
        expect(external_transaction_id).to eq("in_1")
        expect(transaction.original_pre_tax_amount.price_micros).to eq("4160000")
        expect(transaction.original_tax_amount.currency).to eq("EUR")
        expect(transaction.transaction_time).to eq("2026-11-20T10:30:00Z")
        expect(transaction.user_tax_address.region_code).to eq("FR")
        expect(transaction.recurring_transaction.external_transaction_token).to eq("token")
        expect(transaction.recurring_transaction.initial_external_transaction_id).to be_nil
        expect(transaction.recurring_transaction.external_subscription.subscription_type).to eq("RECURRING")
        expect(transaction.external_offer_details.link_type).to eq("LINK_TO_DIGITAL_CONTENT_OFFER")
      end

      described_class.report(**payment, token: "token")
    end

    it "links a renewal to the first payment instead of sending a token" do
      expect(service).to receive(:createexternaltransaction_externaltransaction) do |_parent, transaction, **|
        expect(transaction.recurring_transaction.initial_external_transaction_id).to eq("in_0")
        expect(transaction.recurring_transaction.external_transaction_token).to be_nil
      end

      described_class.report(**payment, initial_external_transaction_id: "in_0")
    end

    it "needs exactly one of the token and the initial transaction" do
      expect { described_class.report(**payment) }.to raise_error(ArgumentError)
      expect { described_class.report(**payment, token: "t", initial_external_transaction_id: "in_0") }.to raise_error(ArgumentError)
    end

    it "counts Google's 409 (already received) as a success, and raises any other error" do
      allow(service).to receive(:createexternaltransaction_externaltransaction).and_raise(google_error(Google::Apis::ClientError, 409))
      expect { described_class.report(**payment, token: "t") }.not_to raise_error

      allow(service).to receive(:createexternaltransaction_externaltransaction).and_raise(google_error(Google::Apis::ClientError, 400))
      expect { described_class.report(**payment, token: "t") }.to raise_error(Google::Apis::ClientError)
    end
  end

  describe ".refund" do
    it "reports a full refund without an amount" do
      expect(service).to receive(:refundexternaltransaction_externaltransaction) do |name, request|
        expect(name).to eq("applications/com.example.app/externalTransactions/in_1")
        expect(request.full_refund).to be_a(Google::Apis::AndroidpublisherV3::FullRefund)
        expect(request.partial_refund).to be_nil
        expect(request.refund_time).to eq("2026-11-20T10:30:00Z")
      end

      described_class.refund(external_transaction_id: "in_1", refund_time: paid_at)
    end

    it "reports a partial refund of a pre-tax amount, with its refund id" do
      expect(service).to receive(:refundexternaltransaction_externaltransaction) do |_name, request|
        expect(request.full_refund).to be_nil
        expect(request.partial_refund.refund_id).to eq("in_1-refund-1")
        expect(request.partial_refund.refund_pre_tax_amount.price_micros).to eq("1000000")
        expect(request.partial_refund.refund_pre_tax_amount.currency).to eq("EUR")
      end

      described_class.refund(external_transaction_id: "in_1", refund_time: paid_at, pre_tax_micros: 1_000_000, currency: "eur", refund_id: "in_1-refund-1")
    end

    it "counts a refused full refund as done when Google already refunded the transaction" do
      allow(service).to receive(:refundexternaltransaction_externaltransaction).and_raise(google_error(Google::Apis::ClientError, 400))
      allow(service).to receive(:getexternaltransaction_externaltransaction)
        .with("applications/com.example.app/externalTransactions/in_1")
        .and_return(Google::Apis::AndroidpublisherV3::ExternalTransaction.new(transaction_state: "TRANSACTION_REFUNDED"))
      expect { described_class.refund(external_transaction_id: "in_1", refund_time: paid_at) }.not_to raise_error

      allow(service).to receive(:getexternaltransaction_externaltransaction)
        .and_return(Google::Apis::AndroidpublisherV3::ExternalTransaction.new(transaction_state: "TRANSACTION_REPORTED"))
      expect { described_class.refund(external_transaction_id: "in_1", refund_time: paid_at) }.to raise_error(Google::Apis::ClientError)
    end

    it "reads the current pre-tax amount of a transaction" do
      allow(service).to receive(:getexternaltransaction_externaltransaction).with("applications/com.example.app/externalTransactions/in_1").and_return(
        Google::Apis::AndroidpublisherV3::ExternalTransaction.new(current_pre_tax_amount: Google::Apis::AndroidpublisherV3::Price.new(price_micros: "7500000"))
      )

      expect(described_class.current_pre_tax_micros("in_1")).to eq(7_500_000)
    end

    it "needs a currency and a refund id for a partial refund" do
      expect { described_class.refund(external_transaction_id: "in_1", refund_time: paid_at, pre_tax_micros: 1) }.to raise_error(ArgumentError)
    end
  end
end
