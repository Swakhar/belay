# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "dummy/config/environment"
require "belay"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
