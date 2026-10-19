# frozen_string_literal: true

module Belay
  # Runs a workflow's steps in order against a Run, writing a checkpoint row for each
  # one's output. This is the minimal version: it always starts from the beginning and
  # writes every step (no resuming past already-checkpointed steps - Phase 1e's next
  # commit), and it writes a step's row only after the block returns (no "started"
  # row before the call - also the next commit). Killing the process mid-run with this
  # version loses the in-flight step entirely; nothing here proves resume yet.
  #
  # Calling this a second time on the same run currently raises ActiveRecord::
  # RecordNotUnique on the first step (Step.create! always takes attempt's DB default
  # of 1, and [run_id, position, attempt] is unique) - not a clean re-run, a hard
  # crash. That's the gap the next commit (skip already-checkpointed steps) closes;
  # spec/belay/executor_spec.rb has a test asserting this exact current behavior so it
  # doesn't silently change out from under that commit.
  class Executor
    # A step declared without kind: (every current README Target API example) can't be
    # written to belay_steps as-is - kind is NOT NULL with no DB default, unlike status.
    # "decision" is the generic catch-all of the four enum values for a step that's
    # plain Ruby, not specifically an llm_call/tool_call/gate. Inferring a real kind
    # from what a step's block actually does is executor work for later (Phase 1g,
    # once there's an llm helper whose use could signal "this one's an llm_call").
    DEFAULT_KIND = "decision"

    def initialize(run)
      @run = run
    end

    def call
      @run.start! if @run.pending?
      outputs = {}

      workflow_class.steps.each_with_index do |step_definition, position|
        outputs[step_definition.name] = run_step(step_definition, position, outputs)
      end

      @run.complete!
      @run
    end

    private

    # @run.pending? above guards start! itself, but not this: nothing here yet decides
    # what an already-running or already-completed run should do (that's what "skip
    # already-checkpointed steps" - the next commit - actually needs to answer).
    def workflow_class
      @run.workflow.constantize
    rescue NameError => e
      raise Error, "belay_runs##{@run.id} names workflow #{@run.workflow.inspect}, which isn't a loadable " \
                   "constant (#{e.message})"
    end

    def run_step(step_definition, position, outputs)
      ctx = Context.new(input: @run.input, outputs: outputs)
      output = step_definition.block.call(ctx)
      checkpoint!(step_definition, position, output)
      output
    end

    def checkpoint!(step_definition, position, output)
      Step.create!(
        run: @run,
        position: position,
        name: step_definition.name,
        kind: step_definition.kind || DEFAULT_KIND,
        status: "succeeded",
        output: output,
        idempotency_key: idempotency_key(position)
      )
    end

    # run_id + position only, matching DESIGN_DECISIONS #3 - stable across attempts, so
    # a retry presents the same key to an external API. Exposing this to a step's own
    # block as ctx.step_idempotency_key is a separate, later commit (Phase 1e); this is
    # just what gets written to the row, which can't wait for that since idempotency_key
    # is NOT NULL on belay_steps.
    def idempotency_key(position)
      "#{@run.id}:#{position}"
    end
  end
end
