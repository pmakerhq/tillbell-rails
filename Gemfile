source "https://rubygems.org"

gemspec

rails_version = ENV.fetch("RAILS_VERSION", ">= 8.0")
gem "rails", rails_version
# Rails 8.0 does not support json 3 ("unknown keyword: quirks_mode" in to_json).
gem "json", "< 3" if rails_version.start_with?("~> 8.0")
gem "sqlite3"
gem "puma"

gem "rspec-rails"
gem "json_schemer"
gem "rubocop-rails-omakase", require: false
