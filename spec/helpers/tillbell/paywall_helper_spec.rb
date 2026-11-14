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

    it "moves an App Store subscription by buying the target product alone" do
      app_store = create_app_store_subscription(user, product_id: "app_solo")
      input = Nokogiri::HTML.fragment(builder.plan_change(to: :family, from: app_store) { "Family" }).at_css("input")

      expect(input.attributes.transform_values(&:value)).to include("value" => "app_family", "checked" => "checked")
      expect(input.attributes).not_to include("data-old-purchase-token", "data-replacement-mode", "data-base-plan-id")
    end

    it "renders a plan with the ids of the store of the app" do
      helper.request.user_agent = "Example; Hotwire Native iOS; bridge-components: [tillbell];"
      expect(Nokogiri::HTML.fragment(builder.plan_option(plan: :family) { "" }).at_css("input")["value"]).to eq("app_family")

      helper.request.user_agent = "Example; Hotwire Native Android; bridge-components: [tillbell];"
      expect(Nokogiri::HTML.fragment(builder.plan_option(plan: :family) { "" }).at_css("input")["value"]).to eq("app_family:monthly")
    end

    it "renders an App Store-only plan with its App Store id in a browser, and nothing in the Android app" do
      Tillbell.plans = [ { name: :pro, app_store_product_id: "app.pro.monthly" } ]

      helper.request.user_agent = "Mozilla/5.0 (Macintosh) Safari/605.1"
      expect(Nokogiri::HTML.fragment(builder.plan_option(plan: :pro) { "" }).at_css("input")["value"]).to eq("app.pro.monthly")

      helper.request.user_agent = "Example; Hotwire Native Android; bridge-components: [tillbell];"
      expect(builder.plan_option(plan: :pro) { "" }).to eq("")
    end

    it "refuses an App Store move to the current plan" do
      app_store = create_app_store_subscription(user, product_id: "app_solo")

      expect { builder.plan_change(to: :solo, from: app_store) { "Solo" } }.to raise_error(ArgumentError, /current plan/)
    end

    it "refuses a plan that is not in Tillbell.plans" do
      expect { builder.plan_change(to: :gold, from: current) { "Gold" } }.to raise_error(ArgumentError, /not in Tillbell.plans/)
    end
  end
end
