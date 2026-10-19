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
    end
  end
end
