# Hardcoded three-step executor for the Phase 0 spike (see belay-planning/COMMITS.md).
# No DSL, no provider abstraction — just enough to prove checkpointing works.
class SpikeExecutor
  STEPS = [
    ->(_run) { { step: "fetch_invoice" } },
    ->(_run) { { step: "extract_total" } },
    ->(_run) { { step: "book_payment" } }
  ].freeze

  def initialize(run)
    @run = run
  end

  def call
    STEPS.each_with_index do |step, position|
      # (run_id, position) is the spike's idempotency key; the row is committed before the call.
      row = Step.find_or_create_by!(run: @run, position: position) { |s| s.status = "started" }
      next if row.status == "succeeded"

      output = step.call(@run)
      row.update!(status: "succeeded", output: output)
    end
    @run
  end
end
