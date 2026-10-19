# frozen_string_literal: true

module Belay
  # Runs a workflow's steps in order against a Run. Each attempt writes its row as
  # "started" - its own transaction, committed before the block runs - then the block
  # runs, then the row is updated to "succeeded" or "failed" - a second, independent
  # transaction. No transaction spans the block call itself (DESIGN_DECISIONS #4): if
  # the block is killed, the "started" row is already committed and visible, which is
  # the whole point - a crash now leaves evidence of exactly where it happened,
  # instead of losing the step silently.
  #
  # A step already checkpointed "succeeded" is skipped - its stored output is reused
  # to build later steps' Context, and its block never runs again. A step found
  # "started" (orphaned by a crash) resumes using the SAME row. A step's block
  # *raising* (as opposed to the process being killed) is caught here and marked
  # "failed" with the error recorded, then retried - up to step(..., retries: N)
  # additional attempts, each its own row sharing the position's idempotency_key -
  # or re-raised once attempts are exhausted. retries: defaults to 0 (one attempt;
  # a raise still gets marked failed with the error, just with nothing left to retry).
  #
  # Deciding whether retrying an orphaned started row found on resume is actually safe
  # (idempotent: true) vs. needing a human (needs_review) is still two separate,
  # later commits - this only answers "was it already done" and "did retries run out,"
  # not "is it safe to redo something a crash interrupted mid-flight."
  #
  # retries: is a different, narrower kind of safety than that idempotent: gate. It's
  # the step author opting a specific step into automatic retry - the same contract
  # every job-retry system has (Sidekiq's retry:, ActiveJob's retry_on): declaring it
  # does not make a step's side effects safe to repeat, it says the author has
  # already made them safe (or the step has none). A step whose block charges a card
  # and then raises will be retried exactly as declared, with no additional gate -
  # that's what ctx.step_idempotency_key (a later commit) is for passing to an
  # idempotent-aware external API, not something this executor enforces on the
  # author's behalf. idempotent:/needs_review, by contrast, is about retrying
  # something nobody asked this executor to retry at all - a crash with no author
  # opt-in either way. The two commits are separate because the safety question is
  # different, not because one is "done" and the other "also needed."
  class Executor
    # A step declared without kind: (every current README Target API example) can't be
    # written to belay_steps as-is - kind is NOT NULL with no DB default, unlike status.
    # "decision" is the generic catch-all of the four enum values for a step that's
    # plain Ruby, not specifically an llm_call/tool_call/gate. Inferring a real kind
    # from what a step's block actually does is executor work for later (Phase 1g,
    # once there's an llm helper whose use could signal "this one's an llm_call").
    DEFAULT_KIND = "decision"

    # What one step's execution needs, bundled so passing it around doesn't mean a
    # five-plus-argument parameter list on every private method below.
    StepRun = Struct.new(:step_definition, :position, :outputs, :max_attempts, keyword_init: true)

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

    def run_step(step_definition, position, outputs)
      max_attempts = 1 + (step_definition.options[:retries] || 0)
      step_run = StepRun.new(step_definition: step_definition, position: position, outputs: outputs,
                             max_attempts: max_attempts)
      dispatch(step_run, latest_attempt(position))
    end

    # Step#status has five legal values. A row found already failed/skipped/
    # needs_review (outside of the "ran out of retries" case this commit now handles
    # for failed) was left that way for a reason this executor can't evaluate yet
    # (the idempotent:/needs_review policy, still two separate later commits) -
    # re-running it like an orphaned started row would be guessing.
    def dispatch(step_run, existing) # rubocop:disable Metrics/MethodLength
      case existing&.status
      when nil
        attempt_step(step_run, attempt: 1)
      when "started"
        attempt_step(step_run, attempt: existing.attempt, reuse: existing)
      when "succeeded"
        symbolize_output(existing.output)
      when "failed"
        retry_or_raise(step_run, existing)
      else
        raise unsafe_to_rerun_error(step_run, existing)
      end
    end

    def unsafe_to_rerun_error(step_run, existing)
      Error.new(
        "belay_steps##{existing.id} at position #{step_run.position} is #{existing.status.inspect} - " \
        "re-running it isn't safe without the idempotent:/needs_review policy, which doesn't exist yet"
      )
    end

    def retry_or_raise(step_run, existing)
      if existing.attempt < step_run.max_attempts
        attempt_step(step_run, attempt: existing.attempt + 1)
      else
        raise Error, "belay_steps##{existing.id} at position #{step_run.position} failed on its final attempt " \
                     "(#{existing.attempt}/#{step_run.max_attempts}): #{existing.error}"
      end
    end

    # Loops in-process across retries (no separate Executor#call per attempt): each
    # failure is caught and marked on its own row by run_attempt, then either a fresh
    # attempt follows or the error is re-raised once max_attempts is reached.
    def attempt_step(step_run, attempt:, reuse: nil)
      loop do
        step = reuse || start_checkpoint!(step_run, attempt)
        output, error = run_attempt(step_run, step)
        return output unless error

        raise error if attempt >= step_run.max_attempts

        attempt += 1
        reuse = nil
      end
    end

    # One attempt: run the block, checkpoint the result. Returns [output, nil] on
    # success or [nil, error] on failure - never raises itself, so the retry loop
    # above decides whether to try again or propagate.
    def run_attempt(step_run, step)
      ctx = Context.new(input: @run.input, outputs: step_run.outputs)
      output = step_run.step_definition.block.call(ctx)
      step.update!(status: "succeeded", output: output)
      [output, nil]
    rescue StandardError => e
      step.update!(status: "failed", error: { "class" => e.class.name, "message" => e.message })
      [nil, e]
    end

    def start_checkpoint!(step_run, attempt)
      Step.create!(
        run: @run,
        position: step_run.position,
        attempt: attempt,
        name: step_run.step_definition.name,
        kind: step_run.step_definition.kind || DEFAULT_KIND,
        status: "started",
        idempotency_key: idempotency_key(step_run.position)
      )
    end

    # attempt is no longer always 1 (retries), so the latest attempt's row is what a
    # resume/skip decision must look at, not an arbitrary one.
    def latest_attempt(position)
      Step.where(run: @run, position: position).order(attempt: :desc).first
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
