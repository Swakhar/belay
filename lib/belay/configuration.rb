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

    # Gates who can load Belay::Engine's mounted dashboard: a ->(request) { boolean }
    # proc, called on every request. nil by default - deliberately NOT "open to
    # anyone" by default, since the dashboard shows prompts, responses, costs and
    # approve/reject actions. Belay::ApplicationController raises a clear error if
    # this is still nil when a request actually arrives, rather than quietly
    # serving it unauthenticated. See lib/belay/application_controller.rb.
    attr_accessor :authenticate_with

    # How long a ctx.llm(..., cacheable: true) entry stays valid, in seconds.
    # nil means never expires. One global setting, not a per-call override -
    # cacheable: is already the one knob a step author needs; a second
    # ttl: keyword on every ctx.llm call would be more API surface for a
    # distinction most workflows don't need to make per-step.
    attr_accessor :cache_ttl

    def initialize
      @lease_duration = 300
      @heartbeat_interval = 30
      @provider = nil
      @authenticate_with = nil
      @cache_ttl = 7 * 24 * 60 * 60 # 7 days
    end
  end
end
