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
       lease_owner lease_expires_at error started_at finished_at
       replay_of_id replay_model].each do |column|
      expect(content).to include(":#{column}")
    end
    expect(content).to include("add_index :belay_runs, :idempotency_key, unique: true")
    expect(content).to include("add_foreign_key :belay_runs, :belay_runs, column: :replay_of_id")
  end

  it "creates a timestamped belay_steps migration that is syntactically valid Ruby" do
    run_generator

    migration = migration_file("db/migrate/create_belay_steps.rb")
    expect(migration).to match(%r{db/migrate/\d{14}_create_belay_steps\.rb\z})
    expect { RubyVM::InstructionSequence.compile_file(migration) }.not_to raise_error
  end

  it "defines belay_steps with a unique index on [run_id, position, attempt], not on idempotency_key" do
    run_generator

    content = File.read(migration_file("db/migrate/create_belay_steps.rb"))

    expect(content).to include("create_table :belay_steps, id: :uuid")
    %w[run_id position name kind status input output provider model input_tokens
       output_tokens cost_cents latency_ms attempt idempotency_key error
       resolved_by resolved_at].each do |column|
      expect(content).to include(":#{column}")
    end

    # Regression guard: a dropped null: false or changed default here wouldn't be caught by
    # the live-Postgres check in this file's description (that one only proves FK/uniqueness).
    expect(content).to include("t.uuid :run_id, null: false")
    expect(content).to include("t.string :idempotency_key, null: false")
    expect(content).to include('t.string :status, null: false, default: "started"')
    expect(content).to include("t.integer :attempt, null: false, default: 1")

    expect(content).to include("add_foreign_key :belay_steps, :belay_runs, column: :run_id")
    expect(content).to include("add_index :belay_steps, [:run_id, :position, :attempt], unique: true")
    expect(content).not_to match(/add_index :belay_steps, :idempotency_key/)
  end

  it "orders belay_steps after belay_runs, so the foreign key has something to point at" do
    run_generator

    runs_migration = File.basename(migration_file("db/migrate/create_belay_runs.rb"))
    steps_migration = File.basename(migration_file("db/migrate/create_belay_steps.rb"))

    expect(runs_migration).to be < steps_migration
  end

  it "creates a timestamped belay_approvals migration that is syntactically valid Ruby" do
    run_generator

    migration = migration_file("db/migrate/create_belay_approvals.rb")
    expect(migration).to match(%r{db/migrate/\d{14}_create_belay_approvals\.rb\z})
    expect { RubyVM::InstructionSequence.compile_file(migration) }.not_to raise_error
  end

  it "defines belay_approvals with FKs into both belay_runs and belay_steps, step_id unique" do
    run_generator

    content = File.read(migration_file("db/migrate/create_belay_approvals.rb"))

    expect(content).to include("create_table :belay_approvals, id: :uuid")
    %w[run_id step_id status decided_by decided_at edited_payload].each do |column|
      expect(content).to include(":#{column}")
    end

    expect(content).to include("t.uuid :run_id, null: false")
    expect(content).to include("t.uuid :step_id, null: false")
    expect(content).to include('t.string :status, null: false, default: "pending"')

    expect(content).to include("add_foreign_key :belay_approvals, :belay_runs, column: :run_id")
    expect(content).to include("add_foreign_key :belay_approvals, :belay_steps, column: :step_id")
    expect(content).to include("add_index :belay_approvals, :step_id, unique: true")
    expect(content).to include("add_index :belay_approvals, :status")
  end

  it "orders belay_approvals after both belay_runs and belay_steps, so both FKs have something to point at" do
    run_generator

    runs_migration = File.basename(migration_file("db/migrate/create_belay_runs.rb"))
    steps_migration = File.basename(migration_file("db/migrate/create_belay_steps.rb"))
    approvals_migration = File.basename(migration_file("db/migrate/create_belay_approvals.rb"))

    expect(runs_migration).to be < approvals_migration
    expect(steps_migration).to be < approvals_migration
  end

  def migration_file(relative_path)
    base = File.basename(relative_path, ".rb")
    Dir.glob(File.join(destination_root, File.dirname(relative_path), "*_#{base}.rb")).first
  end
end
