# frozen_string_literal: true

# Model specs need real tables. Rather than hand-maintain a second copy of the schema
# that could drift from lib/generators/belay/install, invoke that generator for real
# into a throwaway sandbox under spec/dummy/tmp (already gitignored) and migrate from
# there. If belay:install ever breaks, every spec run fails loudly at boot, not just
# the generator's own spec.

require "rails/generators"
require "active_record"

module Belay
  module TestSchema
    SANDBOX = Rails.root.join("tmp/schema_sandbox")

    def self.sync!
      FileUtils.rm_rf(SANDBOX)
      Rails.application.load_generators
      Rails::Generators.invoke("belay:install", [], destination_root: SANDBOX.to_s)

      # Each sync regenerates the migrations with fresh timestamps, so schema_migrations
      # from a previous run never match these new version numbers - a plain db:migrate
      # would try to recreate tables that already exist. Always start from an empty
      # database instead (this is the test DB; nothing here is meant to persist anyway).
      ActiveRecord::Base.establish_connection(:test)
      begin
        ActiveRecord::Tasks::DatabaseTasks.drop_current
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::Tasks::DatabaseNotDefined
        nil
      end
      ActiveRecord::Tasks::DatabaseTasks.create_current
      ActiveRecord::Base.establish_connection(:test)
      ActiveRecord::MigrationContext.new(SANDBOX.join("db/migrate")).migrate
    end
  end
end

Belay::TestSchema.sync!
