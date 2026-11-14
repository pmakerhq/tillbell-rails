RSpec.describe Tillbell do
  describe ".store" do
    it "names the store of the Hotwire Native app, with or without the tillbell component" do
      expect(described_class.store("Example iOS; Hotwire Native iOS; Turbo Native iOS; bridge-components: [haptic];")).to eq(:app_store)
      expect(described_class.store("Example; Hotwire Native Android; Turbo Native Android; bridge-components: [tillbell];")).to eq(:google_play)
    end

    it "is nil in a browser" do
      expect(described_class.store("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/604.1")).to be_nil
      expect(described_class.store(nil)).to be_nil
    end
  end

  describe ".native?" do
    def user_agent(components) = "Example; Hotwire Native Android; Turbo Native Android; bridge-components: [#{components}];"

    it "is true when the app registered the tillbell component, wherever it is in the list" do
      [ "tillbell", "tillbell haptic", "haptic tillbell", "haptic tillbell push" ].each do |components|
        expect(described_class.native?(user_agent(components))).to be(true), components
      end
    end

    it "is true on iOS too, the component list is the same" do
      expect(described_class.native?("Example; Hotwire Native iOS; bridge-components: [tillbell];")).to be(true)
    end

    it "is false without the component, for a lookalike name, in a browser or without a user agent" do
      [ "haptic push", "tillbell-ios", "my-tillbell", "" ].each do |components|
        expect(described_class.native?(user_agent(components))).to be(false), components
      end
      expect(described_class.native?("Mozilla/5.0 (Linux; Android 15) Chrome/130")).to be(false)
      expect(described_class.native?(nil)).to be(false)
    end
  end
end
