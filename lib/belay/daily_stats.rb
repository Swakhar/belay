# frozen_string_literal: true

module Belay
  # How many REAL provider calls (an llm_call step where cache_hit: false - a
  # hit or a rule-auto-settled gate made no call at all) this install made per
  # 100 runs, by day. Backs the dashboard's Stats page - plain Ruby, not an
  # ActiveRecord model of its own: there's no belay_daily_stats table, this is
  # a read-only view over belay_runs/belay_steps' own created_at timestamps.
  class DailyStats
    Row = Struct.new(:date, :runs, :real_calls, :calls_per_100_runs, keyword_init: true)

    # Calls are grouped by the STEP's own day, not the owning run's - a run
    # can pause on a gate for a real, unbounded amount of time (nothing times
    # a pending approval out; Phase 4's own rule-learning needs N separate,
    # time-separated approvals to even happen), so a run created Jan 1 whose
    # gate isn't approved until Jan 15 makes its post-gate steps' real calls
    # on Jan 15, not Jan 1. Grouping by the run's day instead would silently
    # mutate Jan 1's historical count every time an old run resumes - exactly
    # backwards for a chart whose whole purpose is "is this week's cost down,"
    # and would make a past day's bar change on a later page load. Runs are
    # still grouped by their OWN created_at below - "how many runs started
    # that day" is a legitimately different question from "how many real
    # calls happened that day," and conflating them was the bug this comment
    # replaced.
    def self.for_range
      calls_by_day = calls_by_day_counts
      runs_by_day = runs_by_day_counts

      days = (calls_by_day.keys + runs_by_day.keys).uniq.sort
      days.map { |date| build_row(date, runs_by_day.fetch(date, 0), calls_by_day.fetch(date, 0)) }
    end

    def self.calls_by_day_counts
      normalized_counts(Step.llm_call.where(cache_hit: false).group("DATE(created_at)").count)
    end
    private_class_method :calls_by_day_counts

    def self.runs_by_day_counts
      normalized_counts(Run.group("DATE(created_at)").count)
    end
    private_class_method :runs_by_day_counts

    # .group("DATE(...)").count's hash keys come back as plain Strings on some
    # adapter/Rails version combinations, real Date objects on others - a raw
    # SQL group-by fragment (not an actual typed column) gives ActiveRecord
    # nothing to infer the cast from. Normalized here, once, so every lookup
    # and every Row's date below is reliably a Date, regardless of which
    # shape the DB adapter actually returned.
    def self.normalized_counts(counts_by_raw_date)
      counts_by_raw_date.transform_keys { |key| key.is_a?(Date) ? key : Date.parse(key.to_s) }
    end
    private_class_method :normalized_counts

    def self.build_row(date, runs, calls)
      Row.new(date: date, runs: runs, real_calls: calls,
              calls_per_100_runs: runs.zero? ? 0.0 : (calls.to_f / runs * 100).round(1))
    end
    private_class_method :build_row
  end
end
