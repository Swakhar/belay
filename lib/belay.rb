# frozen_string_literal: true

require_relative "belay/version"
require_relative "belay/configuration"

module Belay
  class Error < StandardError; end

  class << self
    def configure
      yield config
    end

    # Not thread-safe: a lazy first read from two threads at once could construct
    # two Configuration objects. Unexercised today (only read at Rails boot); revisit
    # once workers read config concurrently with a lazy first access (Phase 1f).
    def config
      @config ||= Configuration.new
    end

    # Test-only. Call after mutating config in a spec so it doesn't leak into others.
    def reset_config!
      @config = nil
    end
  end
end
