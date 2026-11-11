RSpec.describe "Tillbell plans" do
  around do |example|
    original = Tillbell.plans
    Tillbell.plans = [
      { name: "solo", product_id: "app_solo", base_plan_id: "monthly" },
      { name: :family, product_id: "app_family", base_plan_id: "monthly" },
      { name: :family_yearly, product_id: "app_family", base_plan_id: "yearly" }
    ]
    example.run
  ensure
    Tillbell.plans = original
  end

  it "refuses a plan that is not a hash" do
    expect { Tillbell.plans = [ "app_solo:monthly" ] }.to raise_error(ArgumentError, /a plan is a hash/)
  end

  it "builds plans from hashes" do
    expect(Tillbell.plans.first).to eq(Tillbell::Plan.new(name: :solo, product_id: "app_solo", base_plan_id: "monthly"))
  end

  it "finds a plan by name or by Google ids" do
    expect(Tillbell.plan(:family).product_id).to eq("app_family")
    expect(Tillbell.plan("solo").product_id).to eq("app_solo")
    expect(Tillbell.plan(product_id: "app_family", base_plan_id: "yearly").name).to eq(:family_yearly)
    expect(Tillbell.plan(product_id: "app_solo", base_plan_id: "weekly").name).to eq(:solo)
    expect(Tillbell.plan(product_id: "app_family", base_plan_id: "weekly")).to be_nil
    expect(Tillbell.plan(product_id: "other")).to be_nil
  end

  describe ".replacement_mode" do
    it "prorates an upgrade and defers a downgrade" do
      expect(Tillbell.replacement_mode(from: :solo, to: :family)).to eq("CHARGE_PRORATED_PRICE")
      expect(Tillbell.replacement_mode(from: Tillbell.plan(:family_yearly), to: "solo")).to eq("DEFERRED")
    end

    it "refuses an unknown plan and a move to the same plan" do
      expect { Tillbell.replacement_mode(from: :solo, to: :gold) }.to raise_error(ArgumentError, /not in Tillbell.plans/)
      expect { Tillbell.replacement_mode(from: :solo, to: :solo) }.to raise_error(ArgumentError, /same plan/)
    end
  end

  it "is what tillbell:check verifies when no plan is given" do
    expect(Tillbell::Check.new.instance_variable_get(:@plans)).to eq(
      [ { product_id: "app_solo", base_plan_id: "monthly" }, { product_id: "app_family", base_plan_id: "monthly" },
        { product_id: "app_family", base_plan_id: "yearly" } ]
    )
  end
end
