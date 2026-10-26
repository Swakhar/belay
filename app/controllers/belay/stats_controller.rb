# frozen_string_literal: true

module Belay
  # One page, one metric: how many REAL provider calls (llm_call steps where
  # cache_hit: false - a hit made no call at all) this install is making per
  # 100 runs, by day. Exists to make Phase 4's cost-reduction features
  # (caching, rules) visible as a trend, not just as code nobody can see the
  # effect of.
  class StatsController < ApplicationController
    def index
      @daily_stats = Belay::DailyStats.for_range
    end
  end
end
