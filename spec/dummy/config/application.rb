require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "tillbell"

module Dummy
  # Minimal host app used by the test suite.
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.i18n.available_locales = %i[en fr es de ja]
    config.active_job.queue_adapter = :test
    config.action_controller.allow_forgery_protection = false
    config.action_dispatch.show_exceptions = :rescuable
    config.secret_key_base = "dummy"
  end
end
