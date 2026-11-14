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

  it "takes an App Store product id, the Google Play one by default, and needs one of the two" do
    expect(Tillbell.plan(:solo).app_store_product_id).to eq("app_solo")
    Tillbell.plans = [ { name: :pro, app_store_product_id: "app.pro.monthly" } ]

    expect(Tillbell.plan(app_store_product_id: "app.pro.monthly").name).to eq(:pro)
    expect(Tillbell.plan(:pro).product_for(:app_store)).to eq(product_id: "app.pro.monthly", base_plan_id: nil)
    expect(Tillbell::Check.new.instance_variable_get(:@plans)).to be_empty
    expect { Tillbell.plans = [ { name: :none } ] }.to raise_error(ArgumentError, /needs a product_id/)
  end

  it "gives no default App Store product to plans that share a Google Play product, and finds none when ambiguous" do
    expect(Tillbell.plan(:family).app_store_product_id).to be_nil
    expect(Tillbell.plan(:family_yearly).app_store_product_id).to be_nil
    expect(Tillbell.plan(app_store_product_id: "app_family")).to be_nil
    expect(Tillbell.plan).to be_nil

    Tillbell.plans = [ { name: :a, product_id: "p", base_plan_id: "m", app_store_product_id: "x" }, { name: :b, product_id: "q", app_store_product_id: "x" } ]
    expect(Tillbell.plan(app_store_product_id: "x")).to be_nil
  end

  it "is what tillbell:check verifies when no plan is given" do
    expect(Tillbell::Check.new.instance_variable_get(:@plans)).to eq(
      [ { product_id: "app_solo", base_plan_id: "monthly" }, { product_id: "app_family", base_plan_id: "monthly" },
        { product_id: "app_family", base_plan_id: "yearly" } ]
    )
  end
end
