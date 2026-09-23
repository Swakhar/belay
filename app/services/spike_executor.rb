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
      next if checkpointed?(position)

      output = step.call(@run)
      Step.create!(run: @run, position: position, status: "succeeded", output: output)
    end
    @run
  end

  private

  def checkpointed?(position)
    Step.exists?(run_id: @run.id, position: position, status: "succeeded")
  end
end
