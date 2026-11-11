RSpec.describe Tillbell do
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
