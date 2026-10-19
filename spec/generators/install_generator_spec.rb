# frozen_string_literal: true

require "rails/generators/testing/behavior"
require "rails/generators/testing/assertions"
require "generators/belay/install/install_generator"

RSpec.describe Belay::Generators::InstallGenerator do
  include Rails::Generators::Testing::Behavior
  include Rails::Generators::Testing::Assertions
  include FileUtils

  tests described_class
  destination File.expand_path("../../tmp/generator_sandbox", __dir__)

  before { prepare_destination }

  after { FileUtils.rm_rf(destination_root) }

  it "creates a timestamped belay_runs migration that is syntactically valid Ruby" do
    run_generator

    migration = migration_file("db/migrate/create_belay_runs.rb")
    expect(migration).to match(%r{db/migrate/\d{14}_create_belay_runs\.rb\z})

    # Catches a broken .tt template (stray `end`, bad interpolation, ...): substring
    # matching alone would pass even if the generated file can't actually be loaded.
    expect { RubyVM::InstructionSequence.compile_file(migration) }.not_to raise_error
  end

  it "defines the belay_runs table with the columns the executor needs" do
    run_generator

    content = File.read(migration_file("db/migrate/create_belay_runs.rb"))

    expect(content).to include("create_table :belay_runs, id: :uuid")
    %w[workflow workflow_version input status current_position idempotency_key
       lease_owner lease_expires_at error started_at finished_at].each do |column|
      expect(content).to include(":#{column}")
    end
    expect(content).to include("add_index :belay_runs, :idempotency_key, unique: true")
  end

  def migration_file(relative_path)
    base = File.basename(relative_path, ".rb")
    Dir.glob(File.join(destination_root, File.dirname(relative_path), "*_#{base}.rb")).first
  end
end
