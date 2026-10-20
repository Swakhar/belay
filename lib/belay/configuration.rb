# frozen_string_literal: true

module Belay
  class Configuration
    # Seconds a worker holds a run before the janitor may reclaim it. See
    # DESIGN_DECISIONS.md #12 for why 300/30.
    attr_accessor :lease_duration

    # Seconds between heartbeats while a worker has a step in flight.
    attr_accessor :heartbeat_interval

    # The Belay::Provider ctx.llm calls. nil by default - a workflow with no
    # llm-calling steps never touches this, but a step that calls ctx.llm without
    # one configured gets a clear error instead of a confusing NoMethodError on nil.
    attr_accessor :provider

    def initialize
      @lease_duration = 300
      @heartbeat_interval = 30
      @provider = nil
    end
  end
end
