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
  #
  # Skipped for :real_connections examples (spec/crash_spec.rb, spec/concurrency_spec.rb):
  # those need a second, genuinely separate database connection - a spawned OS process
  # (crash_spec.rb) or a real Thread paired with ActiveRecord::Base.connection_pool.
  # with_connection (concurrency_spec.rb) - to see rows as another real worker would,
  # which only works for rows this process has actually COMMITTED, never this
  # transaction's own still-open writes. Named for what it needs (a second real
  # connection), not for how it gets one - a process and a second-connection thread
  # hit the identical constraint. Those specs clean up their own rows explicitly.
  config.around do |example|
    next example.run if example.metadata[:real_connections]

    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    example.run
    ActiveRecord::Base.connection.rollback_transaction
  end
end
