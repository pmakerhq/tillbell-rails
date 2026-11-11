RSpec.describe Pay::GooglePlay::Customer do
  let(:user) { User.create!(email: "grace@example.com") }

  describe ".for" do
    it "creates the owner's Google Play customer with a random account id" do
      customer = described_class.for(user)

      expect(customer).to be_persisted
      expect(customer.processor).to eq("google_play")
      expect(customer.processor_id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    it "returns the same customer, and so the same account id, every time" do
      expect(described_class.for(user)).to eq(described_class.for(user))
      expect(described_class.for(user).processor_id).to eq(described_class.for(user).processor_id)
    end

    it "never puts the owner's e-mail or id in the account id" do
      account_id = described_class.for(user).processor_id

      # "grace" has letters outside 0-9a-f, so a random UUID can never contain it by chance.
      expect(account_id).not_to include("grace")
      expect(account_id).not_to eq(user.id.to_s)
    end

    it "lives next to another Pay processor without becoming the default" do
      user.set_payment_processor(:fake_processor, allow_fake: true)

      described_class.for(user)

      expect(user.reload.payment_processor.processor).to eq("fake_processor")
      expect(user.pay_customers.pluck(:processor)).to contain_exactly("fake_processor", "google_play")
    end
  end

  it "is told apart from the other processors' customers" do
    customer = described_class.for(user)
    stripe_like = user.set_payment_processor(:fake_processor, allow_fake: true)

    expect(customer).to be_google_play
    expect(stripe_like).not_to be_google_play
    expect(Pay::Customer.google_play).to contain_exactly(customer)
  end

  it "sets its processor when created directly" do
    expect(described_class.create!(owner: user).processor).to eq("google_play")
  end

  it "refuses server-side subscriptions, charges and payment methods" do
    customer = described_class.for(user)

    expect { customer.subscribe }.to raise_error(Tillbell::Error, /Android app/)
    expect { customer.charge(100) }.to raise_error(Tillbell::Error)
    expect { customer.add_payment_method("pm") }.to raise_error(Tillbell::Error)
  end
end
