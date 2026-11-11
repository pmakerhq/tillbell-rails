ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rspec/rails"

ActiveRecord::Schema.verbose = false
load Rails.root.join("db/schema.rb")

Dir[File.join(__dir__, "support/**/*.rb")].each { |file| require file }

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.disable_monkey_patching!
  config.order = :random
  config.include ActiveJob::TestHelper
  config.include ActiveSupport::Testing::TimeHelpers

  # No test may reach Google: every call must be stubbed explicitly.
  config.before do
    allow(Tillbell::GooglePlay).to receive(:service).and_raise("Unstubbed call to the Google Play Developer API")
  end
end
