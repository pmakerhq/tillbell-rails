RSpec.describe Tillbell::StripeExternalOffers do
  let(:api) { Tillbell::GooglePlay::ExternalTransactions }
  let(:metadata) { { described_class::TOKEN_KEY => "play-token" } }

  before { allow(api).to receive(:report) }

  def invoice(id: "in_1", billing_reason: "subscription_create", total: 1200, total_excluding_tax: 1000, currency: "eur",
              metadata: self.metadata, country: "fr", subscription: "sub_1")
    Stripe::Invoice.construct_from(
      id: id, billing_reason: billing_reason, total: total, total_excluding_tax: total_excluding_tax, currency: currency,
      created: Time.utc(2026, 11, 20).to_i, status_transitions: { paid_at: Time.utc(2026, 11, 20, 10).to_i },
      customer_address: (country && { country: country }),
      parent: { type: "subscription_details", subscription_details: { subscription: subscription, metadata: metadata } }
    )
  end

  describe ".report_invoice" do
    it "records the first invoice of a subscription and reports it with the app's token" do
      expect(api).to receive(:report).with(
        external_transaction_id: "in_1", pre_tax_micros: 10_000_000, tax_micros: 2_000_000, currency: "EUR", region_code: "FR",
        transaction_time: Time.utc(2026, 11, 20, 10), link_type: "LINK_TO_DIGITAL_CONTENT_OFFER", token: "play-token",
        initial_external_transaction_id: nil
      )

      transaction = described_class.report_invoice(invoice)

      expect(transaction).to be_reported
      expect(transaction).to have_attributes(stripe_invoice_id: "in_1", stripe_subscription_id: "sub_1", external_transaction_token: "play-token")
    end

    it "is idempotent: a second delivery of the same invoice reports nothing more" do
      described_class.report_invoice(invoice)

      expect { described_class.report_invoice(invoice) }.not_to change(Tillbell::ExternalTransaction, :count)
      expect(api).to have_received(:report).once
    end

    it "links each renewal to the first payment of its subscription" do
      described_class.report_invoice(invoice)
      expect(api).to receive(:report).with(hash_including(external_transaction_id: "in_2", token: nil, initial_external_transaction_id: "in_1"))

      renewal = described_class.report_invoice(invoice(id: "in_2", billing_reason: "subscription_cycle"))

      expect(renewal.external_transaction_token).to be_nil
    end

    it "ignores invoices of subscriptions that did not come from an external offer" do
      expect(described_class.report_invoice(invoice(metadata: {}))).to be_nil
      expect(Tillbell::ExternalTransaction.count).to eq(0)
    end

    it "does not report a renewal whose first payment was never recorded, and says so" do
      orphaned = []
      subscriber = Tillbell.on(:external_transaction_orphaned) { |payload| orphaned << payload }

      expect(described_class.report_invoice(invoice(id: "in_9", billing_reason: "subscription_cycle"))).to be_nil

      expect(api).not_to have_received(:report)
      expect(orphaned.last).to eq(stripe_invoice_id: "in_9", stripe_subscription_id: "sub_1")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "does not report a negative invoice (a proration credit after a plan change)" do
      described_class.report_invoice(invoice)

      expect(described_class.report_invoice(invoice(id: "in_2", billing_reason: "subscription_update", total: -500, total_excluding_tax: -416))).to be_nil
      expect(api).to have_received(:report).once
    end

    it "takes the country from the subscription metadata when the invoice has no customer address" do
      transaction = described_class.report_invoice(invoice(country: nil, metadata: metadata.merge(described_class::REGION_KEY => "de")))

      expect(transaction.region_code).to eq("DE")
    end

    it "raises without a country, so the job retries once it is fixed" do
      expect { described_class.report_invoice(invoice(country: nil)) }.to raise_error(Tillbell::Error, /no customer country/)
    end

    it "keeps the payment recorded when Google fails, for the retry to send the same id" do
      allow(api).to receive(:report).and_raise(google_error(Google::Apis::ServerError, 503))

      expect { described_class.report_invoice(invoice) }.to raise_error(Google::Apis::ServerError)
      expect(Tillbell::ExternalTransaction.unreported.pluck(:external_transaction_id)).to eq([ "in_1" ])
    end
  end

  describe ".refund_charge" do
    def charge(amount_refunded:, refunded:)
      Stripe::Charge.construct_from(id: "ch_1", payment_intent: "pi_1", amount_refunded: amount_refunded, refunded: refunded, currency: "eur")
    end

    before do
      allow(Stripe::InvoicePayment).to receive(:list)
        .with(payment: { type: "payment_intent", payment_intent: "pi_1" }, limit: 1)
        .and_return(Stripe::ListObject.construct_from(data: [ { invoice: "in_1" } ]))
    end

    it "reports the refunded amount of a reported payment" do
      described_class.report_invoice(invoice)
      expect(api).to receive(:refund).with(hash_including(external_transaction_id: "in_1", pre_tax_micros: 2_500_000))

      described_class.refund_charge(charge(amount_refunded: 300, refunded: false))
    end

    it "raises when the payment is not recorded yet, so the refund is retried instead of lost" do
      allow(Stripe::Invoice).to receive(:retrieve).with("in_1").and_return(invoice)

      expect { described_class.refund_charge(charge(amount_refunded: 1200, refunded: true)) }.to raise_error(Tillbell::ExternalTransaction::NotReported)
    end

    it "ignores refunds of an orphaned renewal, which Google never had" do
      allow(Stripe::Invoice).to receive(:retrieve).with("in_1").and_return(invoice(billing_reason: "subscription_cycle"))

      expect(described_class.refund_charge(charge(amount_refunded: 1200, refunded: true))).to be_nil
    end

    it "ignores refunds of payments that did not come from an external offer" do
      allow(Stripe::Invoice).to receive(:retrieve).with("in_1").and_return(invoice(metadata: {}))

      expect(described_class.refund_charge(charge(amount_refunded: 1200, refunded: true))).to be_nil
    end
  end

  it "converts Stripe amounts to micros, whatever the currency's decimals" do
    expect(described_class.micros(499, "eur")).to eq(4_990_000)
    expect(described_class.micros(500, "JPY")).to eq(500_000_000)
    expect(described_class.micros(1500, "kwd")).to eq(1_500_000)
  end
end
