RSpec.describe Tillbell::StripeExternalTransactionJob do
  let(:invoice) do
    Stripe::Invoice.construct_from(
      id: "in_1", parent: { subscription_details: { subscription: "sub_1", metadata: { Tillbell::StripeExternalOffers::TOKEN_KEY => "t" } } }
    )
  end

  it "reads the invoice or the charge from Stripe and reports it" do
    allow(Stripe::Invoice).to receive(:retrieve).with("in_1").and_return(invoice)
    allow(Stripe::Charge).to receive(:retrieve).with("ch_1").and_return(:charge)
    expect(Tillbell::StripeExternalOffers).to receive(:report_invoice).with(invoice)
    expect(Tillbell::StripeExternalOffers).to receive(:refund_charge).with(:charge)

    described_class.perform_now("invoice", "in_1")
    described_class.perform_now("refund", "ch_1")
  end

  it "retries a refund that arrives before its payment is reported" do
    allow(Stripe::Charge).to receive(:retrieve).and_return(:charge)
    allow(Tillbell::StripeExternalOffers).to receive(:refund_charge).and_raise(Tillbell::ExternalTransaction::NotReported)

    expect { described_class.perform_now("refund", "ch_1") }.to have_enqueued_job(described_class).with("refund", "ch_1")
  end

  it "says so once a payment could not be reported after 24 hours of retries" do
    allow(Stripe::Invoice).to receive(:retrieve).and_raise(Tillbell::Error, "no country")
    allow(Rails.error).to receive(:report)
    failed = []
    subscriber = Tillbell.on(:external_transaction_failed) { |details| failed << details }

    job = described_class.new("invoice", "in_1")
    job.exception_executions = { "[StandardError]" => 47 }
    job.perform_now

    expect(failed.sole).to include(kind: "invoice", id: "in_1", error: kind_of(Tillbell::Error))
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "Stripe webhooks" do
    def deliver(type, object)
      Pay::Webhooks.instrument(type: "stripe.#{type}", event: Stripe::Event.construct_from(type: type, data: { object: object }))
    end

    around do |example|
      Tillbell.google.external_offers = true
      example.run
    ensure
      Tillbell.google.external_offers = nil
    end

    it "enqueues the paid invoices of subscriptions with a Google Play token, and every refund" do
      expect { deliver("invoice.paid", invoice) }.to have_enqueued_job(described_class).with("invoice", "in_1")
      expect { deliver("charge.refunded", { id: "ch_1" }) }.to have_enqueued_job(described_class).with("refund", "ch_1")
    end

    it "skips invoices without a token" do
      plain = Stripe::Invoice.construct_from(id: "in_2", parent: { subscription_details: { subscription: "sub_2", metadata: {} } })

      expect { deliver("invoice.paid", plain) }.not_to have_enqueued_job(described_class)
    end

    it "does nothing unless external offers are turned on" do
      Tillbell.google.external_offers = nil

      expect { deliver("invoice.paid", invoice) }.not_to have_enqueued_job(described_class)
      expect { deliver("charge.refunded", { id: "ch_1" }) }.not_to have_enqueued_job(described_class)
    end
  end
end
