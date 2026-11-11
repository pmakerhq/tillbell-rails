RSpec.describe Tillbell::PaywallHelper, type: :helper do
  describe "#tillbell_native?" do
    it "reads the request's user agent" do
      helper.request.user_agent = "Example; Hotwire Native Android; bridge-components: [haptic tillbell];"
      expect(helper.tillbell_native?).to be(true)

      helper.request.user_agent = "Example; Hotwire Native Android; bridge-components: [haptic];"
      expect(helper.tillbell_native?).to be(false)
    end
  end

  describe "PaywallBuilder#plan_change" do
    let(:user) { User.create!(email: "ada@example.com") }
    let(:builder) { Tillbell::PaywallBuilder.new(helper) }
    let(:current) do
      Pay::GooglePlay::Subscription.create!(customer: Pay::GooglePlay::Customer.for(user), name: "default", processor_id: "token",
                                            processor_plan: "app_solo", status: "active", data: { base_plan_id: "monthly" })
    end

    around do |example|
      original = Tillbell.plans
      Tillbell.plans = [ { name: :solo, product_id: "app_solo", base_plan_id: "monthly" }, { name: :family, product_id: "app_family", base_plan_id: "monthly" } ]
      example.run
    ensure
      Tillbell.plans = original
    end

    it "renders the checked plan to move to, replacing the current purchase with the mode that suits the move" do
      input = Nokogiri::HTML.fragment(builder.plan_change(to: :family, from: current) { "Family" }).at_css("input")

      expect(input.attributes.transform_values(&:value)).to include(
        "value" => "app_family:monthly", "checked" => "checked", "data-old-purchase-token" => "token",
        "data-replacement-mode" => "CHARGE_PRORATED_PRICE"
      )
    end

    it "refuses a missing or unknown current subscription" do
      expect { builder.plan_change(to: :family, from: nil) { "Family" } }.to raise_error(ArgumentError, /needs the current/)
      current.update!(processor_plan: "other")
      expect { builder.plan_change(to: :family, from: current) { "Family" } }.to raise_error(ArgumentError, /not in Tillbell.plans/)
    end

    it "refuses a plan that is not in Tillbell.plans" do
      expect { builder.plan_change(to: :gold, from: current) { "Gold" } }.to raise_error(ArgumentError, /not in Tillbell.plans/)
    end
  end
end
