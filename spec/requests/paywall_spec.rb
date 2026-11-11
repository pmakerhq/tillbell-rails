RSpec.describe "Paywall" do
  let(:user) { User.create!(email: "ada@example.com") }

  def paywall
    get "/paywall", headers: { "X-User-Id" => user.id.to_s }
    Nokogiri::HTML(response.body).at_css("#paywall")
  end

  it "renders two plans, a restore button and a manage button, wired to the Stimulus controller" do
    html = paywall

    expect(html["data-controller"]).to eq("tillbell")
    expect(html["data-tillbell-account-id-value"]).to eq(Pay::GooglePlay::Customer.for(user).processor_id)
    expect(html["data-tillbell-purchase-url-value"]).to eq("/tillbell/purchases")
    expect(html["data-tillbell-success-url-value"]).to eq("/dashboard")
    expect(JSON.parse(html["data-tillbell-messages-value"])).to include("verifying", "pending", "unavailable", "error")

    plans = html.css("input[type=radio][data-tillbell-target=plan]")
    expect(plans.map { |plan| [ plan["data-product-id"], plan["data-base-plan-id"] ] }).to eq([ %w[premium monthly], %w[premium yearly] ])
    expect(plans.first["checked"]).to eq("checked")
    expect(html.css("[data-tillbell-target=price]").size).to eq(2)

    expect(html.css("button").map { |button| [ button.text, button["data-action"] ] }).to eq([
      [ "Subscribe", "tillbell#purchase" ], [ "Restore purchases", "tillbell#restorePurchases" ], [ "Manage subscription", "tillbell#manage" ]
    ])
  end

  it "falls back to English in a locale without translations" do
    I18n.with_locale(:ja) do
      get "/paywall", headers: { "X-User-Id" => user.id.to_s }
    end
    html = Nokogiri::HTML(response.body).at_css("#paywall")

    expect(html.css("button").map(&:text)).to eq([ "Subscribe", "Restore purchases", "Manage subscription" ])
    expect(JSON.parse(html["data-tillbell-messages-value"])).to include("verifying", "error")
  end

  it "cannot start a purchase until the native component connects" do
    html = paywall

    expect(html.css("input, button").map { |element| element["disabled"] }).to all(eq("disabled"))
    expect(html.at_css("[data-tillbell-target=fallback]").text).to include("Android app")
    expect(html.css("form")).to be_empty
  end

  it "has a polite live region for status messages" do
    status = paywall.at_css("[data-tillbell-target=status]")

    expect(status["role"]).to eq("status")
    expect(status["aria-live"]).to eq("polite")
  end
end

RSpec.describe Tillbell::PaywallHelper, type: :helper do
  let(:user) { User.create!(email: "ada@example.com") }

  it "accepts custom texts, attributes and data attributes" do
    html = Nokogiri::HTML(helper.tillbell_paywall(success_url: "/done", owner: user, class: "paywall", data: { turbo: false }) do |paywall|
      paywall.submit("Go premium", class: "button", data: { testid: "buy" }) + paywall.fallback { "Get the app" }
    end)

    expect(html.at_css("div.paywall")["data-turbo"]).to eq("false")
    expect(html.at_css("div.paywall")["data-controller"]).to eq("tillbell")
    button = html.at_css("button.button")
    expect(button.text).to eq("Go premium")
    expect(button["data-testid"]).to eq("buy")
    expect(button["data-action"]).to eq("tillbell#purchase")
    expect(html.at_css("[data-tillbell-target=fallback]").text).to eq("Get the app")
  end

  it "passes a plan change through to the native app" do
    subscription = instance_double(Pay::GooglePlay::Subscription, processor_id: "old-token")

    html = Nokogiri::HTML(helper.tillbell_paywall(success_url: "/done", owner: user) do |paywall|
      paywall.plan_option(product_id: "premium", base_plan_id: "yearly", replacing: subscription, replacement_mode: "CHARGE_PRORATED_PRICE") { "Yearly" }
    end)

    plan = html.at_css("input")
    expect(plan["data-old-purchase-token"]).to eq("old-token")
    expect(plan["data-replacement-mode"]).to eq("CHARGE_PRORATED_PRICE")
  end

  it "requires a replacement mode for a plan change" do
    expect do
      helper.tillbell_paywall(success_url: "/done", owner: user) do |paywall|
        paywall.plan_option(product_id: "premium", replacing: instance_double(Pay::GooglePlay::Subscription)) { "" }
      end
    end.to raise_error(ArgumentError, /replacement_mode/)
  end

  it "requires an owner" do
    expect { helper.tillbell_paywall(success_url: "/done", owner: nil) { "" } }.to raise_error(ArgumentError, /owner/)
  end
end
