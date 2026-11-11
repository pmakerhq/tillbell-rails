require "rails/generators"
require "generators/tillbell/install/install_generator"

RSpec.describe Tillbell::Generators::InstallGenerator do
  let(:destination) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(destination, "config"))
    File.write(File.join(destination, "config/routes.rb"), "Rails.application.routes.draw do\nend\n")
  end

  after { FileUtils.remove_entry(destination) }

  def run_generator
    described_class.start([ "--quiet" ], destination_root: destination)
  end

  it "creates the initializer, mounts the engine and copies the Stimulus controller" do
    run_generator

    expect(File.read(File.join(destination, "config/initializers/tillbell.rb"))).to include("Tillbell.configure")
    expect(File.read(File.join(destination, "config/routes.rb"))).to include('mount Tillbell::Engine, at: "/tillbell"')
    expect(File.read(File.join(destination, "app/javascript/controllers/tillbell_controller.js")))
      .to include('static component = "tillbell"')
  end

  it "copies no migration, since Tillbell uses Pay's tables" do
    run_generator

    expect(Dir.exist?(File.join(destination, "db"))).to be(false)
  end

  it "prints the Google Play credentials template and the check command" do
    output = capture_output { described_class.start([], destination_root: destination) }

    expect(output).to include("google_service_account:", "pubsub_service_account_email:", "bin/rails tillbell:check",
                              "#google-play-setup")
  end

  def capture_output
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
