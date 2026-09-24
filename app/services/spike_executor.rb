# Hardcoded three-step executor for the Phase 0 spike (see belay-planning/COMMITS.md).
# No DSL, no provider abstraction — just enough to prove checkpointing works.
#
# Each lambda logs a StepInvocation on every call, as a stand-in for a real side effect
# (a booked payment, a sent mail). It is independent of the Step checkpoint, so the crash
# test can compare "times the step body ran" with "times it was checkpointed".
class SpikeExecutor
  STEP_NAMES = %w[fetch_invoice extract_total book_payment].freeze

  STEPS = STEP_NAMES.map do |name|
    lambda do |run|
      StepInvocation.create!(run_id: run.id, step: name)
      { step: name }
    end
  end.freeze

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
