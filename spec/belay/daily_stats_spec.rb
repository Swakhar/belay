# frozen_string_literal: true

RSpec.describe Belay::DailyStats do
  def build_run(created_at:)
    Belay::Run.create!(workflow: "InvoiceWorkflow", workflow_version: "v1", created_at: created_at)
  end

  def build_step(run, kind:, cache_hit: false, position: 0, created_at: run.created_at)
    run.steps.create!(position: position, name: "step#{position}", kind: kind, status: "succeeded",
                      idempotency_key: "#{run.id}:#{position}", cache_hit: cache_hit, created_at: created_at)
  end

  describe ".for_range" do
    it "is empty when there are no runs at all" do
      expect(described_class.for_range).to eq([])
    end

    it "counts an llm_call step with cache_hit: false as a real call, and nothing else" do
      run = build_run(created_at: Time.zone.local(2026, 1, 1, 10))
      build_step(run, kind: "llm_call", cache_hit: false, position: 0)
      build_step(run, kind: "llm_call", cache_hit: true, position: 1) # served from cache - no real call
      build_step(run, kind: "tool_call", cache_hit: false, position: 2) # not an llm_call at all
      build_step(run, kind: "gate", cache_hit: false, position: 3)

      row = described_class.for_range.sole

      expect(row.real_calls).to eq(1)
    end

    it "groups a call by the STEP's own day, not the owning run's - a run paused on a gate for real " \
       "elapsed time must not retroactively change an already-past day's count" do
      run = build_run(created_at: Time.zone.local(2026, 1, 1, 10))
      build_step(run, kind: "llm_call", position: 0, created_at: Time.zone.local(2026, 1, 1, 10))
      # Simulates a gate approved two weeks later: the run was created Jan 1, but this step's
      # real call only happens once a human actually gets to approving the gate.
      build_step(run, kind: "llm_call", position: 1, created_at: Time.zone.local(2026, 1, 15, 9))

      rows = described_class.for_range.index_by(&:date)

      expect(rows[Date.new(2026, 1, 1)].real_calls).to eq(1)
      expect(rows[Date.new(2026, 1, 15)].real_calls).to eq(1)
    end

    it "is 0.0, not an error, for a day with real calls but no run actually CREATED that day - the " \
       "run.zero? guard is reachable, not just defensive, now that calls and runs are grouped " \
       "independently" do
      run = build_run(created_at: Time.zone.local(2026, 1, 1, 10))
      build_step(run, kind: "llm_call", position: 0, created_at: Time.zone.local(2026, 1, 15, 9))

      rows = described_class.for_range.index_by(&:date)

      expect(rows[Date.new(2026, 1, 15)].runs).to eq(0)
      expect(rows[Date.new(2026, 1, 15)].calls_per_100_runs).to eq(0.0)
    end

    it "computes calls_per_100_runs, rounded to one decimal place" do
      day = Time.zone.local(2026, 1, 1, 10)
      run_with_call = build_run(created_at: day)
      build_step(run_with_call, kind: "llm_call")
      build_run(created_at: day)
      build_run(created_at: day)

      row = described_class.for_range.sole

      expect(row.runs).to eq(3)
      expect(row.real_calls).to eq(1)
      expect(row.calls_per_100_runs).to eq(33.3) # 1 / 3 * 100, rounded
    end

    it "is 0.0, not an error or NaN, for a day with runs but no real calls at all" do
      build_run(created_at: Time.zone.local(2026, 1, 1, 10))

      row = described_class.for_range.sole

      expect(row.calls_per_100_runs).to eq(0.0)
    end

    it "returns one row per distinct day, sorted chronologically" do
      build_run(created_at: Time.zone.local(2026, 1, 3, 10))
      build_run(created_at: Time.zone.local(2026, 1, 1, 10))
      build_run(created_at: Time.zone.local(2026, 1, 2, 10))

      dates = described_class.for_range.map(&:date)

      expect(dates).to eq([Date.new(2026, 1, 1), Date.new(2026, 1, 2), Date.new(2026, 1, 3)])
    end
  end
end
