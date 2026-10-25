# frozen_string_literal: true

module Belay
  # Runs a workflow's steps in order against a Run: start/complete the run itself,
  # iterate steps in order, hand each one to StepRunner. The per-step mechanics
  # (checkpointing, resume, retries) are StepRunner's job, not this class's - they're
  # genuinely separate responsibilities, which is why they're split out below rather
  # than all flattened into one large class.
  class Executor
    def initialize(run)
      @run = run
      @step_runner = StepRunner.new(run)
    end

    # catch(:gate_paused), not a rescue: a gate whose when: evaluates true throws
    # this tag (see StepRunner#evaluate_gate!) after already pausing the run and
    # releasing its lease - a throw, not a raise, specifically so it unwinds past
    # run_attempt's rescue StandardError untouched (throw/catch and raise/rescue
    # are separate mechanisms in Ruby; no rescue clause anywhere in between ever
    # sees it), skipping both the generic succeeded/failed checkpoint AND the
    # complete! call below, with no further steps run.
    def call
      @run.start! if @run.pending?
      outputs = {}

      catch(:gate_paused) do
        workflow_class.steps.each_with_index do |step_definition, position|
          outputs[step_definition.name] = @step_runner.run(step_definition, position, outputs)
        end

        # Guarded the same way start! is above: a second call on an already-
        # completed run must be a clean no-op, not InvalidTransitionError on
        # complete! -> complete!.
        @run.complete! if @run.running?
      end

      @run
    end

    private

    # @run.pending? above guards start! itself. complete! above assumes every call to
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

    # Runs one step to completion: checkpointing ("started" before the block, then
    # "succeeded"/"failed" after - no transaction spans the block call itself,
    # DESIGN_DECISIONS #4), resuming an orphaned started row in place, skipping an
    # already-succeeded one (reusing its output, deep-symbolized so a later step's
    # ctx.extract[:key]-style access sees the same shape a fresh run would), and
    # retrying up to step(..., retries: N) additional attempts on a raise, each its
    # own row sharing the position's stable idempotency_key (DESIGN_DECISIONS #3).
    #
    # retries: is a different, narrower kind of safety than the idempotent:/
    # needs_review gate for an orphaned started row: that gate decides whether
    # resuming a crash is actually safe (idempotent: true resumes it; otherwise the
    # row is flagged needs_review and the run stops for a human), where retries:
    # only ever answers "did retries run out" for a row the author already opted in
    # to retrying. retries: is the step author opting a specific step into automatic
    # retry - the same contract
    # every job-retry system has (Sidekiq's retry:, ActiveJob's retry_on): declaring
    # it does not make a step's side effects safe to repeat, it says the author has
    # already made them safe (or the step has none). A step whose block charges a
    # card and then raises will be retried exactly as declared, with no additional
    # gate - that's what ctx.step_idempotency_key is for passing to an idempotent-
    # aware external API, if the author chooses to; nothing here enforces that they
    # do. The two commits are separate because the safety question is different, not
    # because one is "done" and the other "also needed."
    class StepRunner # rubocop:disable Metrics/ClassLength
      # A step declared without kind: (every current README Target API example) can't
      # be written to belay_steps as-is - kind is NOT NULL with no DB default, unlike
      # status. "decision" is the generic catch-all of the four enum values for a step
      # that's plain Ruby, not specifically an llm_call/tool_call/gate. Written at
      # start_checkpoint! time, before the block has run - run_attempt below upgrades
      # it to "llm_call" after the fact if the block actually called ctx.llm and the
      # author never declared kind: explicitly (an explicit kind: is never overridden).
      DEFAULT_KIND = "decision"

      # What one step's execution needs, bundled so passing it around doesn't mean a
      # five-plus-argument parameter list on every private method below.
      StepRun = Struct.new(:step_definition, :position, :outputs, :max_attempts, keyword_init: true)

      def initialize(run)
        @run = run
      end

      def run(step_definition, position, outputs)
        max_attempts = 1 + (step_definition.options[:retries] || 0)
        step_run = StepRun.new(step_definition: step_definition, position: position, outputs: outputs,
                               max_attempts: max_attempts)
        dispatch(step_run, latest_attempt(position))
      end

      private

      # Step#status has six legal values now. "succeeded" and "skipped" resume the
      # same way - reuse the stored output, never re-evaluate (DESIGN_DECISIONS #7:
      # a gate's when: is not re-run against whatever context resume happens to
      # have). needs_review/awaiting_approval were each left that way for a reason
      # this can't resolve itself - re-running either would be guessing, same as a
      # freshly-flagged needs_review row would be if dispatch were called on it
      # again in the same process (it never is, today: flagging always raises
      # right after, see flag_needs_review! below). An awaiting_approval row is
      # resolved the same way: Run#approve!/#reject! move it to succeeded/failed
      # BEFORE the executor is ever invoked again, so dispatch here never actually
      # sees "awaiting_approval" on a row a human has already acted on - this
      # branch only fires if something re-dispatches the run while the gate is
      # genuinely still unresolved.
      def dispatch(step_run, existing) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity
        case existing&.status
        when nil
          attempt_step(step_run, attempt: 1)
        when "started"
          resume_orphaned_started(step_run, existing)
        when "succeeded", "skipped"
          symbolize_output(existing.output)
        when "failed"
          retry_or_raise(step_run, existing)
        when "needs_review"
          raise unsafe_to_rerun_error(step_run, existing)
        when "awaiting_approval"
          raise Error, "belay_steps##{existing.id} at position #{step_run.position} is awaiting_approval - " \
                       "resolve it via run.approve!/reject! first"
        else
          raise Error, "belay_steps##{existing.id} at position #{step_run.position} has unrecognized status " \
                       "#{existing.status.inspect} - refusing to guess what resuming it should do"
        end
      end

      # DESIGN_DECISIONS #2: a step found "started" was interrupted before anything
      # caught an exception for it (retries: never applies) - nobody asked this
      # executor to retry it. idempotent: true is the author's explicit sign-off that
      # redoing it is safe; without it, retrying automatically would be guessing
      # exactly as much as the unsafe_to_rerun_error cases below - so instead the row
      # is flagged needs_review for a human, exactly as decision #2 says, and the run
      # stops (flag_needs_review! raises; nothing resumes a needs_review run yet -
      # that's dashboard/resolve-action work, not built).
      #
      # options[:idempotent] == true, not bare truthiness: nothing validates step
      # option values at declare time (unlike kind:, see validate_step_kind! in
      # Workflow), so idempotent: "false" - a string, not a boolean, from an author
      # who doesn't think in Ruby truthiness - would otherwise be truthy and silently
      # authorize resuming a step the author was trying to mark unsafe.
      #
      # Applies to an orphaned gate exactly the same way, even though re-evaluating
      # a pure when: condition is arguably always safe regardless of idempotent: -
      # a gate crashing mid-evaluation is rare and not this commit's problem to
      # solve; an author who wants one resumed without flagging needs_review can
      # already declare idempotent: true on it today, same as any step.
      def resume_orphaned_started(step_run, existing)
        return attempt_step(step_run, attempt: existing.attempt, reuse: existing) if idempotent?(step_run)

        flag_needs_review!(step_run, existing)
      end

      def idempotent?(step_run)
        step_run.step_definition.options[:idempotent] == true
      end

      def flag_needs_review!(step_run, existing)
        reason = "belay_steps##{existing.id} at position #{step_run.position} was left \"started\" (by a " \
                 "crash, or by another worker concurrently running this same step - no lease mechanism " \
                 "exists yet to tell which) and step :#{step_run.step_definition.name} isn't declared " \
                 "idempotent: true"
        existing.update!(status: "needs_review", error: { "reason" => reason })
        # pause!, not leaving status at "running": otherwise Run.where(status: "running")
        # can't distinguish a run legitimately executing from one silently stuck on a
        # human. Run#pause! already exists (running -> paused) for exactly this shape
        # of "stopped, not failed, waiting on something external."
        @run.pause!
        raise Error, "#{reason} - flagged needs_review; the run is paused until a human resolves it"
      end

      def unsafe_to_rerun_error(step_run, existing)
        Error.new(
          "belay_steps##{existing.id} at position #{step_run.position} is needs_review - resolve it via " \
          "run.resolve_needs_review! first"
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
      # failure is caught and marked on its own row by run_attempt, then either a
      # fresh attempt follows or the error is re-raised once max_attempts is reached.
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

      # One attempt: run the block (or, for a gate, evaluate when:), checkpoint the
      # result. Returns [output, nil] on success or [nil, error] on failure - never
      # raises itself, so the retry loop above decides whether to try again or
      # propagate. context is built before the risky call so the rescue clause can
      # still reach its llm_metadata - ctx.llm may have already made a real, billed
      # provider call before the block went on to raise for an unrelated reason;
      # that cost is recorded on the failed row too, not dropped.
      #
      # A gate reuses this same checkpoint/retry machinery rather than a separate
      # path: start_checkpoint! already writes kind: :gate correctly (it was never
      # nil, so DEFAULT_KIND never kicks in), and evaluate_gate! below stands in for
      # block.call - when: false settles the row exactly like a step's output
      # would, just under status: "skipped" instead of "succeeded". when: true
      # takes a different exit entirely (throw, not return) - see evaluate_gate!.
      def run_attempt(step_run, step)
        context = build_context(step_run)
        output = run_block(step_run, context, step)
        step.update!(status: settled_status(step_run), output: output, **extra_step_attrs(step_run, context))
        [output, nil]
      rescue StandardError => e
        step.update!(status: "failed", error: { "class" => e.class.name, "message" => e.message },
                     **extra_step_attrs(step_run, context))
        [nil, e]
      end

      def run_block(step_run, context, step)
        return evaluate_gate!(step_run, context, step) if step_run.step_definition.kind == :gate

        step_run.step_definition.block.call(context)
      end

      def settled_status(step_run)
        step_run.step_definition.kind == :gate ? "skipped" : "succeeded"
      end

      # when: false settles normally (returns nil, caller checkpoints "skipped").
      # when: true pauses right here instead: this step's own row becomes
      # "awaiting_approval" (not "succeeded", not "failed" - run_attempt's own
      # checkpoint line below never runs, since throw skips straight past it, same
      # as it skips the rescue), the run is paused and its lease released, then
      # throw :gate_paused unwinds all the way up to Executor#call's catch,
      # skipping every remaining step and the complete! call - cleanly, not via an
      # exception any rescue StandardError could intercept or retry: could retry.
      # That's the actual fix for the previous commit's documented retries: gap:
      # there's no raise on this path anymore for retries: to apply to at all.
      #
      # The three writes below are wrapped in one transaction, and the throw
      # happens AFTER it (not inside it): a process killed mid-transaction rolls
      # back to the gate's original "started" row, which is the already-handled
      # crash path (idempotent?/needs_review) - not a new, worse state. Without
      # the transaction, a crash between step.update! and @run.pause! would leave
      # the step "awaiting_approval" while the run stays "running": JanitorJob's
      # own query (status: running, lease expired or none - today's realistic
      # case, since inline Workflow.start never takes a lease at all) would pick
      # that run back up and hand it to ResumeRunJob, which has no rescue around
      # Executor.new(run).call - dispatch's awaiting_approval branch just raises,
      # uncaught, forever, every lease cycle, and the run never reaches "paused"
      # at all. Caught by review before this landed; keeping the throw outside the
      # transaction block (rather than inside it) is deliberate too - a throw is
      # not an exception, so it wouldn't trigger Rails' own rollback-on-exception
      # path, but there's no reason to rely on that distinction when the simpler
      # structure (commit first, throw after) removes the question entirely.
      def evaluate_gate!(step_run, context, step)
        condition = step_run.step_definition.options[:when]
        return nil unless condition.call(context)

        ActiveRecord::Base.transaction do
          step.update!(status: "awaiting_approval")
          @run.pause!
          @run.release_lease!
        end
        throw :gate_paused
      end

      def extra_step_attrs(step_run, context)
        return {} if context.nil?

        attrs = context.llm_metadata
        attrs = attrs.merge(kind: "llm_call") if step_run.step_definition.kind.nil? && !attrs.empty?
        attrs
      end

      def build_context(step_run)
        Context.new(
          input: @run.input,
          outputs: step_run.outputs,
          step_idempotency_key: idempotency_key(step_run.position),
          model_override: @run.replay_model
        )
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
      # string keys, even though the very same Hash returned fresh from a block in
      # this same process would have symbol keys. Without this, a step block written
      # like the README's own ctx.extract[:total_cents] would get nil instead of the
      # real value the moment the step it depends on was skipped rather than freshly
      # run - silently, since symbol access on a string-keyed Hash just returns nil,
      # not an error. Only one level deep matters here (only Hash has
      # deep_symbolize_keys); scalars and bare Arrays pass through untouched.
      def symbolize_output(output)
        output.is_a?(Hash) ? output.deep_symbolize_keys : output
      end

      # run_id + position only, matching DESIGN_DECISIONS #3 - stable across attempts,
      # so a retry presents the same key to an external API. Used both for what's
      # written to the row (idempotency_key is NOT NULL on belay_steps) and for what's
      # exposed to the step's own block as ctx.step_idempotency_key, via build_context
      # above - the two must be the same value, which is why both read from this one
      # method.
      def idempotency_key(position)
        "#{@run.id}:#{position}"
      end
    end
  end
end
