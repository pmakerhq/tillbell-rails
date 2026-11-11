require "rake"

RSpec.describe "tillbell:check" do
  let(:google) do
    ActiveSupport::OrderedOptions.new.merge(
      package_name: "com.example.app", pubsub_service_account_email: "push@project.iam.gserviceaccount.com",
      service_account_json: { "type" => "service_account", "client_email" => "api@project.iam.gserviceaccount.com",
                              "private_key" => OpenSSL::PKey::RSA.generate(2048).to_pem }.to_json
    )
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tillbell:check")
    Rake::Task["tillbell:check"].reenable
    allow(Tillbell).to receive(:google).and_return(google)
  end

  it "prints one line per check and succeeds when nothing is wrong" do
    expect { Rake::Task["tillbell:check"].invoke }
      .to output(/OK   Android package name: com\.example\.app.*Everything is in place\./m).to_stdout
  end

  it "reminds that Google was not asked" do
    expect { Rake::Task["tillbell:check"].invoke }.to output(/ONLINE=1/).to_stdout
  end

  it "aborts with a pointer to the README when something will not work" do
    google.pubsub_service_account_email = nil

    expect { Rake::Task["tillbell:check"].invoke }
      .to raise_error(SystemExit).and output(/FAIL Notification sender/).to_stdout.and output(/Google Play setup/).to_stderr
  end

  describe "ONLINE and PLANS" do
    let(:service) { double("AndroidPublisherService") }
    let(:subscription) do
      Google::Apis::AndroidpublisherV3::Subscription.new(
        base_plans: [ Google::Apis::AndroidpublisherV3::BasePlan.new(base_plan_id: "monthly", state: "ACTIVE") ]
      )
    end

    around do |example|
      saved = ENV.to_h.slice("ONLINE", "PLANS")
      example.run
    ensure
      %w[ONLINE PLANS].each { |name| ENV.delete(name) }
      ENV.update(saved)
    end

    before do
      allow(Tillbell::GooglePlay).to receive(:service).and_return(service)
      allow(service).to receive(:get_purchase_subscriptionsv2).and_raise(Google::Apis::ClientError.new("unknown", status_code: 404))
      allow(service).to receive(:get_monetization_subscription).and_return(subscription)
    end

    it "asks Google about each plan of PLANS, whatever the spaces around them" do
      ENV["ONLINE"] = "1"
      ENV["PLANS"] = " premium:monthly , premium:monthly "

      expect { Rake::Task["tillbell:check"].invoke }.to output(/OK   Subscription premium \(base plan monthly\): active/).to_stdout
      expect(service).to have_received(:get_monetization_subscription).twice
    end

    it "checks Tillbell.plans when PLANS is not set" do
      original = Tillbell.plans
      Tillbell.plans = [ { name: :premium, product_id: "premium", base_plan_id: "monthly" } ]
      ENV["ONLINE"] = "1"

      expect { Rake::Task["tillbell:check"].invoke }.to output(/OK   Subscription premium \(base plan monthly\): active/).to_stdout
    ensure
      Tillbell.plans = original
    end

    it "does not ask Google for ONLINE=0 or ONLINE=false" do
      %w[0 false].each do |off|
        Rake::Task["tillbell:check"].reenable
        ENV["ONLINE"] = off

        expect { Rake::Task["tillbell:check"].invoke }.to output(/Google was not asked/).to_stdout
      end
      expect(Tillbell::GooglePlay).not_to have_received(:service)
    end
  end
end
