require "tillbell/test_helpers"

# Google Play stubs for the specs. Response builders live in Tillbell::TestHelpers, which host
# apps use too.
module GooglePlayHelpers
  # Makes Google answer +response+ for +purchase_token+.
  def stub_google_subscription(purchase_token, response)
    allow(Tillbell::GooglePlay).to receive(:subscription).with(purchase_token).and_return(response)
  end

  # A Google API error as raised by the google-apis gems.
  def google_error(klass, status)
    klass.new("Google error", status_code: status)
  end
end

RSpec.configure do |config|
  config.include Tillbell::TestHelpers
  config.include GooglePlayHelpers
end
