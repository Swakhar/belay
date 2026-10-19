# frozen_string_literal: true

module Belay
  # Runs a workflow's steps in order against a Run. Each step writes its row as
  # "started" - its own transaction, committed before the block runs - then the block
  # runs, then the row is updated to "succeeded" with the output - a second,
  # independent transaction. No transaction spans the block call itself (DESIGN_
  # DECISIONS #4): if the block is killed or raises, the "started" row is already
  # committed and visible, which is the whole point - a crash now leaves evidence of
  # exactly where it happened, instead of losing the step silently.
  #
  # A step already checkpointed "succeeded" is skipped - its stored output is reused
  # to build later steps' Context, and its block never runs again. A step found
  # "started" (orphaned by a crash) is re-run using the SAME row rather than creating
  # a new one: deciding whether that's actually safe to retry (idempotent: true) vs.
  # needing a human (needs_review) is still two separate, later commits - this one
  # only answers "was it already done," not "is it safe to redo."
  #
  # Still minimal: no new row per attempt yet (also a later commit) - an orphaned
  # started row is updated in place, so attempt stays 1 even on a retried step.
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

      # Guarded the same way start! is above: a second call on an already-completed
      # run must be a clean no-op, not InvalidTransitionError on complete! -> complete!.
      @run.complete! if @run.running?
      @run
    end

    private

    # @run.pending? above guards start! itself. complete! below assumes every call to
    # this method runs all the way to the end successfully - calling this again on a
    # run some OTHER code path already moved to failed/cancelled (nothing does that
    # yet) would skip/re-run steps as normal but never re-reach complete!, since
    # status never returns to "running". Not handled; stated here, not silently.
    def workflow_class
      @run.workflow.constantize
    rescue NameError => e
      raise Error, "belay_runs##{@run.id} names workflow #{@run.workflow.inspect}, which isn't a loadable " \
                   "constant (#{e.message})"
    end

    # Step#status has five legal values (started succeeded failed skipped
    # needs_review), but this commit only has an answer for two of them. A row found
    # already failed/skipped/needs_review was left that way for a reason this
    # executor has no way to evaluate yet (that's the idempotent:/needs_review policy,
    # still two separate later commits) - re-running it like an orphaned started row
    # would be guessing, so it raises instead of guessing.
    def run_step(step_definition, position, outputs)
      # attempt is always 1 today (one row per position), so plain find_by is correct
      # right now - but has no defined tie-break once a second attempt row exists.
      # .order(attempt: :desc) costs nothing today and means the retries commit
      # doesn't silently need to remember to add it.
      existing = Step.where(run: @run, position: position).order(attempt: :desc).first

      case existing&.status
      when nil, "started"
        run_and_checkpoint(step_definition, position, outputs, existing)
      when "succeeded"
        symbolize_output(existing.output)
      else
        raise Error, "belay_steps##{existing.id} at position #{position} is #{existing.status.inspect} - " \
                     "re-running it isn't safe without the idempotent:/needs_review policy, which doesn't exist yet"
      end
    end

    def run_and_checkpoint(step_definition, position, outputs, existing)
      ctx = Context.new(input: @run.input, outputs: outputs)
      step = existing || start_checkpoint!(step_definition, position)
      output = step_definition.block.call(ctx)
      step.update!(status: "succeeded", output: output)
      output
    end

    def start_checkpoint!(step_definition, position)
      Step.create!(
        run: @run,
        position: position,
        name: step_definition.name,
        kind: step_definition.kind || DEFAULT_KIND,
        status: "started",
        idempotency_key: idempotency_key(position)
      )
    end

    # A step's output read back from the DB (jsonb round-trips through JSON) has
    # string keys, even though the very same Hash returned fresh from a block in this
    # same process would have symbol keys. Without this, a step block written like
    # the README's own ctx.extract[:total_cents] would get nil instead of the real
    # value the moment the step it depends on was skipped rather than freshly run -
    # silently, since symbol access on a string-keyed Hash just returns nil, not an
    # error. Only one level deep matters here (only Hash has deep_symbolize_keys);
    # scalars and bare Arrays pass through untouched.
    def symbolize_output(output)
      output.is_a?(Hash) ? output.deep_symbolize_keys : output
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
