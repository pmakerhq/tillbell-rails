module Tillbell
  module Generators
    # Sets Tillbell up in a Rails app: +rails generate tillbell:install+.
    #
    # Tillbell stores everything in Pay's tables, so there is no migration to copy.
    # Run Pay's own installation first if the app does not use Pay yet.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates the Tillbell initializer, mounts the engine, copies the paywall Stimulus controller and prints the Google Play credentials template."

      def create_initializer
        copy_file "initializer.rb", "config/initializers/tillbell.rb"
      end

      def mount_engine
        route 'mount Tillbell::Engine, at: "/tillbell"'
      end

      def copy_stimulus_controller
        copy_file "tillbell_controller.js", "app/javascript/controllers/tillbell_controller.js"
      end

      def install_bridge_package
        if File.exist?(File.join(destination_root, "config/importmap.rb"))
          run "bin/importmap pin @hotwired/hotwire-native-bridge"
        else
          say "Add the Hotwire Native bridge to your JavaScript dependencies: " \
            "npm install @hotwired/hotwire-native-bridge", :yellow
        end
      end

      # The part that happens on Google's side, with the credentials to fill in.
      def show_next_steps
        readme "next_steps.txt"
      end
    end
  end
end
