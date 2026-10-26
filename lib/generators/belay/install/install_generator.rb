# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record/migration"

module Belay
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_belay_runs_migration
        migration_template "create_belay_runs.rb.tt", "db/migrate/create_belay_runs.rb"
      end

      def create_belay_steps_migration
        migration_template "create_belay_steps.rb.tt", "db/migrate/create_belay_steps.rb"
      end

      # Last: belay_approvals FKs into both belay_runs and belay_steps, so its
      # migration needs a timestamp after both of theirs - each migration_template
      # call gets a fresh, later timestamp than the one before it, same reasoning
      # that already orders steps after runs above.
      def create_belay_approvals_migration
        migration_template "create_belay_approvals.rb.tt", "db/migrate/create_belay_approvals.rb"
      end

      # No FK into belay_runs/belay_steps - a cache entry isn't tied to any
      # particular run, so there's no ordering dependency forcing this after
      # the others. Still last, for the same reason every new migration this
      # gem has ever added has been: one predictable place to look.
      def create_belay_cache_entries_migration
        migration_template "create_belay_cache_entries.rb.tt", "db/migrate/create_belay_cache_entries.rb"
      end
    end
  end
end
