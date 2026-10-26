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

  it "defines belay_cache_entries with a unique key and no FK into belay_runs/belay_steps" do
    run_generator

    content = File.read(migration_file("db/migrate/create_belay_cache_entries.rb"))

    expect(content).to include("create_table :belay_cache_entries, id: :uuid")
    %w[key content hits expires_at].each { |column| expect(content).to include(":#{column}") }
    expect(content).to include("t.string :key, null: false")
    expect(content).to include("t.integer :hits, null: false, default: 0")
    expect(content).to include("add_index :belay_cache_entries, :key, unique: true")
    expect(content).not_to include("add_foreign_key :belay_cache_entries")
  end

  it "creates a timestamped belay_cache_entries migration that is syntactically valid Ruby" do
    run_generator

    migration = migration_file("db/migrate/create_belay_cache_entries.rb")
    expect(migration).to match(%r{db/migrate/\d{14}_create_belay_cache_entries\.rb\z})
    expect { RubyVM::InstructionSequence.compile_file(migration) }.not_to raise_error
  end

  it "adds cache_hit to belay_steps, defaulting to false" do
    run_generator

    content = File.read(migration_file("db/migrate/create_belay_steps.rb"))

    expect(content).to include("t.boolean :cache_hit, null: false, default: false")
  end

  it "adds a nullable rule_applied_id to belay_steps, with no FK in that same migration" do
    run_generator

    content = File.read(migration_file("db/migrate/create_belay_steps.rb"))

    expect(content).to include("t.uuid :rule_applied_id")
    expect(content).not_to include("add_foreign_key :belay_steps, :belay_rules")
  end

  it "defines belay_rules with the identity columns, a learning counter and status, and the FK back " \
     "into belay_steps" do
    run_generator

    content = File.read(migration_file("db/migrate/create_belay_rules.rb"))

    expect(content).to include("create_table :belay_rules, id: :uuid")
    %w[workflow workflow_version gate_name context_key consistent_approvals status
       invalidated_at].each do |column|
      expect(content).to include(":#{column}")
    end

    expect(content).to include("t.string :context_key, null: false")
    expect(content).to include("t.integer :consistent_approvals, null: false, default: 0")
    expect(content).to include('t.string :status, null: false, default: "learning"')

    expect(content).to include("add_foreign_key :belay_steps, :belay_rules, column: :rule_applied_id")
    expect(content).to include("[:workflow, :workflow_version, :gate_name, :context_key],")
    expect(content).to include("unique: true, name: \"index_belay_rules_on_identity\"")
  end

  it "creates a timestamped belay_rules migration that is syntactically valid Ruby" do
    run_generator

    migration = migration_file("db/migrate/create_belay_rules.rb")
    expect(migration).to match(%r{db/migrate/\d{14}_create_belay_rules\.rb\z})
    expect { RubyVM::InstructionSequence.compile_file(migration) }.not_to raise_error
  end

  it "orders belay_rules after belay_steps and belay_cache_entries" do
    run_generator

    steps_migration = File.basename(migration_file("db/migrate/create_belay_steps.rb"))
    cache_entries_migration = File.basename(migration_file("db/migrate/create_belay_cache_entries.rb"))
    rules_migration = File.basename(migration_file("db/migrate/create_belay_rules.rb"))

    expect(steps_migration).to be < rules_migration
    expect(cache_entries_migration).to be < rules_migration
  end

  def migration_file(relative_path)
    base = File.basename(relative_path, ".rb")
    Dir.glob(File.join(destination_root, File.dirname(relative_path), "*_#{base}.rb")).first
  end
end
