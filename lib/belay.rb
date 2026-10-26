# frozen_string_literal: true

module Belay
  # Error must exist before any required file below, since several of them (e.g.
  # FakeProvider::ScriptExhaustedError) subclass it at load time, not lazily.
  class Error < StandardError; end

  require_relative "belay/version"
  require_relative "belay/configuration"
  require_relative "belay/application_record"
  require_relative "belay/run"
  require_relative "belay/step"
  require_relative "belay/approval"
  require_relative "belay/cache_entry"
  require_relative "belay/workflow"
  require_relative "belay/context"
  require_relative "belay/provider_response"
  require_relative "belay/provider"
  require_relative "belay/fake_provider"
  require_relative "belay/anthropic_provider"
  require_relative "belay/executor"
  require_relative "belay/resume_run_job"
  require_relative "belay/janitor_job"
  require_relative "belay/engine"

  # Raised by Run#start!/pause!/resume!/complete!/fail!/cancel! when the current
  # status doesn't allow the requested transition.
  class InvalidTransitionError < Error; end

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
