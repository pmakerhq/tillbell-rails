RSpec.describe Tillbell::SyncJob do
  it "syncs the purchase" do
    allow(Pay::GooglePlay::Subscription).to receive(:sync)

    described_class.perform_now("purchase-token", revoked: true)

    expect(Pay::GooglePlay::Subscription).to have_received(:sync).with("purchase-token", revoked: true)
  end

  it "retries when Google is unavailable" do
    allow(Pay::GooglePlay::Subscription).to receive(:sync).and_raise(google_error(Google::Apis::ServerError, 503))

    described_class.perform_now("purchase-token")

    expect(described_class).to have_been_enqueued.with("purchase-token")
  end

  it "drops a token Google does not know" do
    allow(Pay::GooglePlay::Subscription).to receive(:sync).and_raise(google_error(Google::Apis::ClientError, 410))

    expect { described_class.perform_now("purchase-token") }.not_to raise_error
    expect(described_class).not_to have_been_enqueued
  end
end

RSpec.describe Tillbell::SyncJob, "with a configuration problem" do
  it "fails loudly instead of dropping the notification" do
    allow(Pay::GooglePlay::Subscription).to receive(:sync).and_raise(google_error(Google::Apis::ClientError, 403))

    expect { described_class.perform_now("purchase-token") }.to raise_error(Google::Apis::ClientError)
  end
end
