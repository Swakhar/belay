# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"
require "belay"
require_relative "support/database"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Belay.config is memoized at the module level; reset it after every example so a
  # spec that mutates it (e.g. via Belay.configure) can never leak into another.
  config.after { Belay.reset_config! }

  # No rspec-rails, so no built-in transactional fixtures. Wrap every example in a
  # transaction and roll it back, so DB-touching specs never leak rows into another.
  config.around do |example|
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    example.run
    ActiveRecord::Base.connection.rollback_transaction
  end
end
