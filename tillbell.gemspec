require_relative "lib/tillbell/version"

Gem::Specification.new do |spec|
  spec.name = "tillbell"
  spec.version = Tillbell::VERSION
  spec.authors = [ "pmakerhq" ]
  spec.summary = "Self-hosted Google Play subscriptions for Rails + Hotwire Native apps, built on Pay."
  spec.description = "Tillbell adds a Google Play processor to the Pay gem: server-side purchase verification, " \
    "acknowledgment, real-time developer notifications and a paywall that talks to a Hotwire Native bridge component."
  spec.homepage = "https://github.com/pmakerhq/tillbell-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["{app,config,contract,lib}/**/*", "MIT-LICENSE", "README.md", "CHANGELOG.md"]

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "pay", ">= 12.0"
  spec.add_dependency "google-apis-androidpublisher_v3", ">= 0.100"
  spec.add_dependency "googleauth", ">= 1.11"
end
