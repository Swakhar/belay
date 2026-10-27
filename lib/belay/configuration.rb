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

    # How many consistent, unedited approve!s of the exact same gate occurrence
    # (same workflow_version, gate_name, and input/outputs - see Belay::Rule)
    # it takes before that occurrence is learned as a rule. One global setting,
    # same reasoning as cache_ttl above - a per-gate override is more API
    # surface than any workflow has asked for yet. Does not by itself make
    # anything auto-approve; see feat(rules): auto-settle a gate when a
    # learned rule matches, before ever pausing.
    attr_accessor :rule_approval_threshold

    # Extra CSS appended, in the layout's own <style> tag, right after the
    # dashboard's compiled Tailwind build - not a replacement for it. Appended
    # rather than merged means a same-specificity rule (redeclaring .btn-primary,
    # say) wins by ordinary cascade order, no !important required; nil by
    # default renders nothing extra. A plain String, not a path or an asset -
    # this gem has no asset pipeline opinion to lean on (see Engine.stylesheet's
    # own comment), so the host app owns wherever this string actually comes from.
    attr_accessor :custom_css

    def initialize
      @lease_duration = 300
      @heartbeat_interval = 30
      @provider = nil
      @authenticate_with = nil
      @cache_ttl = 7 * 24 * 60 * 60 # 7 days
      @rule_approval_threshold = 3
      @custom_css = nil
    end
  end
end
