# frozen_string_literal: true

module Belay
  class Configuration
    # Seconds a worker holds a run before the janitor may reclaim it. See
    # DESIGN_DECISIONS.md #12 for why 300/30.
    attr_accessor :lease_duration

    # Seconds between heartbeats while a worker has a step in flight.
    attr_accessor :heartbeat_interval

    def initialize
      @lease_duration = 300
      @heartbeat_interval = 30
    end
  end
end
