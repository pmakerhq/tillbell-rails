require "json_schemer"

# The bridge contract is the specification of the native libraries (tillbell-android,
# tillbell-ios): every example must match its schema, and every schema needs an example.
RSpec.describe "Bridge contract" do
  contract = Tillbell::Engine.root.join("contract")
  schemas = contract.glob("*.json").to_h { |path| [ path.basename(".json").to_s, JSONSchemer.schema(path) ] }

  it "has a schema for every message" do
    expect(schemas.keys).to contain_exactly(
      "products.request", "products.reply", "purchase.request", "purchase.reply", "restore.request", "restore.reply", "manage.request"
    )
  end

  schemas.each_key do |name|
    it "has at least one example for #{name}" do
      expect(contract.glob("examples/#{name}*.json")).not_to be_empty
    end
  end

  contract.glob("examples/*.json").each do |example|
    name = example.basename(".json").to_s.split(".").first(2).join(".")

    it "accepts the #{example.basename} example" do
      errors = schemas.fetch(name).validate(JSON.parse(example.read)).map { |error| error["error"] }

      expect(errors).to be_empty
    end
  end

  {
    "purchase.request" => [
      { "productId" => "premium", "basePlanId" => "monthly" },
      { "productId" => "premium", "basePlanId" => "monthly", "obfuscatedAccountId" => "a", "oldPurchaseToken" => "t" },
      { "productId" => "premium", "basePlanId" => "monthly", "obfuscatedAccountId" => "a" * 65 }
    ],
    "purchase.reply" => [ { "result" => "purchased" }, { "result" => "refunded" } ],
    "products.reply" => [ { "result" => "ok" } ],
    "restore.reply" => [ { "result" => "ok", "purchases" => [ { "productId" => "premium" } ] } ]
  }.each do |name, messages|
    messages.each do |message|
      it "rejects the #{name} message #{JSON.generate(message)}" do
        expect(schemas.fetch(name).valid?(message)).to be(false)
      end
    end
  end
end
