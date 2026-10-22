# frozen_string_literal: true

RSpec.describe Belay::Executor do
  before do
    stub_const("ExecutorSpecWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id

      step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      step(:verify) { |ctx| ctx.extract[:total_cents].positive? }
      step(:book, kind: "tool_call") { |_ctx| "booked" }
    end)
  end

  def build_run(workflow_class: ExecutorSpecWorkflow, input: { invoice_id: 42 })
    run = Belay::Run.create!(
      workflow: workflow_class.name,
      workflow_version: workflow_class.workflow_version,
      input: input
    )
    # Reloading simulates the realistic case: input read back from Postgres has string
    # keys (jsonb round-trips through JSON), not the symbol keys passed at creation.
    run.reload
  end

  it "executes every step in declaration order, in one pass" do
    run = build_run

    described_class.new(run).call

    expect(run.steps.order(:position).pluck(:name)).to eq(%w[extract verify book])
  end

  it "builds each step's context from the run's input and every prior step's output" do
    run = build_run

    described_class.new(run).call

    steps = run.steps.order(:position).index_by(&:name)
    expect(steps["extract"].output).to eq("total_cents" => 4200)
    expect(steps["verify"].output).to eq(true)
    expect(steps["book"].output).to eq("booked")
  end

  it "checkpoints status succeeded on every step" do
    run = build_run

    described_class.new(run).call

    expect(run.steps.pluck(:status)).to all(eq("succeeded"))
  end

  it "defaults kind to decision when a step doesn't declare one, but respects an explicit kind:" do
    run = build_run

    described_class.new(run).call

    steps = run.steps.order(:position).index_by(&:name)
    expect(steps["extract"].kind).to eq("decision")
    expect(steps["verify"].kind).to eq("decision")
    expect(steps["book"].kind).to eq("tool_call")
  end

  describe "ctx.llm" do
    after { Belay.reset_config! }

    it "persists provider, model, tokens, cost and latency onto the step row after a successful call" do
      response = Belay::ProviderResponse.new(content: "ok", model: "claude-sonnet-5-5", input_tokens: 10,
                                             output_tokens: 5, cost_cents: 18, latency_ms: 420)
      Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [response]) }
      stub_const("LlmExecutorSpecWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:ask) { |ctx| ctx.llm(model: "claude-sonnet-5-5", prompt: "hi") }
      end)
      run = build_run(workflow_class: LlmExecutorSpecWorkflow)

      described_class.new(run).call

      step = run.steps.sole
      expect(step).to have_attributes(provider: "Belay::FakeProvider", model: "claude-sonnet-5-5",
                                      input_tokens: 10, output_tokens: 5, cost_cents: 18, latency_ms: 420)
    end

    it "upgrades kind to llm_call when the step didn't declare one, but respects an explicit kind:" do
      Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: %w[a b]) }
      stub_const("LlmKindExecutorSpecWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:ask) { |ctx| ctx.llm(model: "x", prompt: "hi") }
        step(:tag, kind: "tool_call") { |ctx| ctx.llm(model: "x", prompt: "hi") }
      end)
      run = build_run(workflow_class: LlmKindExecutorSpecWorkflow)

      described_class.new(run).call

      steps = run.steps.order(:position).index_by(&:name)
      expect(steps["ask"].kind).to eq("llm_call")
      expect(steps["tag"].kind).to eq("tool_call")
    end

    it "does not touch kind, provider or token columns for a step that never calls ctx.llm" do
      run = build_run

      described_class.new(run).call

      step = run.steps.find_by(name: "extract")
      expect(step).to have_attributes(kind: "decision", provider: nil, model: nil, input_tokens: nil,
                                      output_tokens: nil, cost_cents: nil, latency_ms: nil)
    end

    it "persists llm_metadata even when the step block raises after a successful ctx.llm call" do
      response = Belay::ProviderResponse.new(content: "ok", model: "claude-sonnet-5-5", cost_cents: 18)
      Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [response]) }
      stub_const("LlmFailsAfterExecutorSpecWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:ask) do |ctx|
          ctx.llm(model: "x", prompt: "hi")
          raise "boom after the billed call"
        end
      end)
      run = build_run(workflow_class: LlmFailsAfterExecutorSpecWorkflow)

      expect { described_class.new(run).call }.to raise_error("boom after the billed call")

      step = run.steps.sole
      expect(step).to have_attributes(status: "failed", cost_cents: 18, kind: "llm_call")
    end

    it "persists llm_metadata onto the failed row when schema: validation itself is what fails" do
      response = Belay::ProviderResponse.new(content: { "total_cents" => "not an integer" }, model: "claude-sonnet-5-5",
                                             cost_cents: 18)
      Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [response]) }
      schema = { type: "object", properties: { total_cents: { type: "integer" } }, required: [:total_cents] }
      stub_const("LlmSchemaFailsExecutorSpecWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:ask) { |ctx| ctx.llm(model: "x", prompt: "hi", schema: schema) }
      end)
      run = build_run(workflow_class: LlmSchemaFailsExecutorSpecWorkflow)

      expect { described_class.new(run).call }.to raise_error(Belay::Context::SchemaValidationError)

      step = run.steps.sole
      expect(step).to have_attributes(status: "failed", cost_cents: 18, model: "claude-sonnet-5-5", kind: "llm_call")
    end
  end

  it "writes a stable idempotency_key of run_id:position for each step" do
    run = build_run

    described_class.new(run).call

    steps = run.steps.order(:position).to_a
    expect(steps.map(&:idempotency_key)).to eq(
      ["#{run.id}:0", "#{run.id}:1", "#{run.id}:2"]
    )
  end

  it "exposes ctx.step_idempotency_key to the block, equal to what's written to the row" do
    seen_in_block = nil
    stub_const("ExecutorSpecIdempotencyKeyWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) do |ctx|
        seen_in_block = ctx.step_idempotency_key
        "done"
      end
    end)
    run = build_run(workflow_class: ExecutorSpecIdempotencyKeyWorkflow)

    described_class.new(run).call

    expect(seen_in_block).to eq("#{run.id}:0")
    expect(run.steps.find_by(position: 0).idempotency_key).to eq(seen_in_block)
  end

  it "keeps ctx.step_idempotency_key the same across every retry attempt (DESIGN_DECISIONS #3)" do
    seen_per_attempt = []
    stub_const("ExecutorSpecIdempotencyKeyAcrossRetriesWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:flaky, retries: 2) do |ctx|
        seen_per_attempt << ctx.step_idempotency_key
        raise "fail" if seen_per_attempt.size < 3

        "done"
      end
    end)
    run = build_run(workflow_class: ExecutorSpecIdempotencyKeyAcrossRetriesWorkflow)

    described_class.new(run).call

    expect(seen_per_attempt).to eq(["#{run.id}:0", "#{run.id}:0", "#{run.id}:0"])
  end

  it "returns the run" do
    run = build_run

    expect(described_class.new(run).call).to equal(run)
  end

  it "passes the run's input through to the first step's context" do
    run = build_run(input: { invoice_id: 7 })

    described_class.new(run).call

    expect(run.steps.find_by(name: "extract").output).to eq("total_cents" => 700)
  end

  describe "run status" do
    it "transitions pending -> running -> completed over a successful call" do
      run = build_run
      expect(run.status).to eq("pending")

      described_class.new(run).call

      expect(run.status).to eq("completed")
    end
  end

  # This proves ordering (the row exists before the block runs), not full crash
  # durability across a real process boundary. spec_helper.rb wraps every example in
  # one begin_transaction(joinable: false), and AR's create! joins rather than opens a
  # new transaction when one's already active - so the "started" INSERT below isn't
  # committed at all in this suite, just an uncommitted statement on the one shared
  # connection, visible only via read-your-own-writes. The second example makes that
  # isolation boundary concrete instead of just asserting it in this comment. Full
  # crash-proof testing (did it survive SIGKILL, not just "is it on the connection")
  # is Phase 1h's job, with a real subprocess like the Phase 0 spike's.
  it "writes the started row before the block runs - visible to a query from inside the block itself" do
    visible_during_block = nil
    stub_const("ExecutorSpecVisibilityWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) do |_ctx|
        visible_during_block = Belay::Step.find_by(position: 0)&.status
        "done"
      end
    end)
    run = build_run(workflow_class: ExecutorSpecVisibilityWorkflow)

    described_class.new(run).call

    expect(visible_during_block).to eq("started")
  end

  it "is not actually committed in this suite - a different thread's own connection never sees it" do
    # ActiveRecord's connection pool is thread-local: calling with_connection on the
    # SAME thread just returns the one already checked out, which would trivially see
    # its own uncommitted write. A real Thread gets its own pooled connection, giving
    # an actual second observer instead of read-your-own-writes in disguise.
    visible_on_other_thread = :not_set
    stub_const("ExecutorSpecIsolationWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) do |_ctx|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |other|
            visible_on_other_thread = other.select_value(
              "select status from belay_steps where position = 0"
            )
          end
        end.join
        "done"
      end
    end)
    run = build_run(workflow_class: ExecutorSpecIsolationWorkflow)

    described_class.new(run).call

    expect(visible_on_other_thread).to be_nil
  end

  describe "a step block that raises" do
    it "propagates the error, marking the step failed with the error recorded - not started, not missing" do
      stub_const("ExecutorSpecRaisingWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
        step(:boom) { |_ctx| raise "step blew up" }
      end)
      run = build_run(workflow_class: ExecutorSpecRaisingWorkflow)

      expect { described_class.new(run).call }.to raise_error(RuntimeError, "step blew up")

      steps = run.steps.order(:position).index_by(&:name)
      expect(steps["extract"].status).to eq("succeeded")
      expect(steps["boom"].status).to eq("failed")
      expect(steps["boom"].attempt).to eq(1)
      expect(steps["boom"].error).to eq("class" => "RuntimeError", "message" => "step blew up")
      expect(run.reload.status).to eq("running") # start! ran; complete! never got the chance to
    end
  end

  describe "retries:" do
    def build_flaky_workflow(fail_times:, retries: nil)
      calls = 0
      step_options = retries.nil? ? {} : { retries: retries }

      stub_const("ExecutorSpecFlakyWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:flaky, **step_options) do |_ctx|
          calls += 1
          raise "attempt #{calls} failed" if calls <= fail_times

          "succeeded on attempt #{calls}"
        end
      end)

      [ExecutorSpecFlakyWorkflow, -> { calls }]
    end

    it "retries a failing step up to retries: times, each attempt its own row, succeeding within budget" do
      workflow_class, calls = build_flaky_workflow(fail_times: 2, retries: 2)
      run = build_run(workflow_class: workflow_class)

      described_class.new(run).call

      expect(calls.call).to eq(3)
      attempts = run.steps.where(position: 0).order(:attempt)
      expect(attempts.pluck(:attempt, :status)).to eq([[1, "failed"], [2, "failed"], [3, "succeeded"]])
      expect(attempts.last.output).to eq("succeeded on attempt 3")
      expect(attempts.first.idempotency_key).to eq(attempts.last.idempotency_key) # stable across attempts
    end

    it "raises once retries: is exhausted, leaving one failed row per attempt and no more" do
      workflow_class, calls = build_flaky_workflow(fail_times: 99, retries: 1)
      run = build_run(workflow_class: workflow_class)

      expect { described_class.new(run).call }.to raise_error(RuntimeError, "attempt 2 failed")

      expect(calls.call).to eq(2)
      attempts = run.steps.where(position: 0).order(:attempt)
      expect(attempts.pluck(:attempt, :status)).to eq([[1, "failed"], [2, "failed"]])
    end

    it "defaults to 0 retries (one attempt) when retries: isn't declared - no behavior change from before" do
      workflow_class, calls = build_flaky_workflow(fail_times: 99, retries: nil)
      run = build_run(workflow_class: workflow_class)

      expect { described_class.new(run).call }.to raise_error(RuntimeError, "attempt 1 failed")

      expect(calls.call).to eq(1)
      expect(run.steps.where(position: 0).count).to eq(1)
    end

    it "resumes an orphaned started row into the retry loop at its own attempt number, not attempt 1" do
      stub_const("ExecutorSpecResumeRetryWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:flaky, retries: 2, idempotent: true) { |_ctx| "recovered" }
      end)
      run = build_run(workflow_class: ExecutorSpecResumeRetryWorkflow)
      # Simulates a crash after attempt 2's started row committed but before the
      # block (or the update after it) ever ran.
      Belay::Step.create!(
        run: run, position: 0, attempt: 2, name: "flaky", kind: "decision", status: "started",
        idempotency_key: "#{run.id}:0"
      )

      described_class.new(run).call

      attempts = run.steps.where(position: 0).order(:attempt)
      expect(attempts.pluck(:attempt, :status)).to eq([[2, "succeeded"]])
      expect(attempts.first.output).to eq("recovered")
    end

    it "creates a fresh row for the next attempt when a RESUMED row also fails, not corrupting the resumed row" do
      calls = 0
      stub_const("ExecutorSpecResumeRetryFailsAgainWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:flaky, retries: 2, idempotent: true) do |_ctx|
          calls += 1
          raise "attempt 2 (resumed) failed too" if calls == 1

          "recovered on attempt 3"
        end
      end)
      run = build_run(workflow_class: ExecutorSpecResumeRetryFailsAgainWorkflow)
      # Same crash as above, but this time the resumed attempt 2 ALSO fails - proving
      # the loop starts a fresh attempt 3 row rather than reusing attempt 2's row a
      # second time (which would silently corrupt that row's attempt history).
      Belay::Step.create!(
        run: run, position: 0, attempt: 2, name: "flaky", kind: "decision", status: "started",
        idempotency_key: "#{run.id}:0"
      )

      described_class.new(run).call

      attempts = run.steps.where(position: 0).order(:attempt)
      expect(attempts.pluck(:attempt, :status)).to eq([[2, "failed"], [3, "succeeded"]])
      expect(attempts.first.error).to eq("class" => "RuntimeError", "message" => "attempt 2 (resumed) failed too")
      expect(attempts.last.output).to eq("recovered on attempt 3")
    end
  end

  describe "idempotent:, an orphaned started row, and needs_review" do
    def simulate_crashed_step(run)
      Belay::Step.create!(
        run: run, position: 0, name: "extract", kind: "decision", status: "started",
        idempotency_key: "#{run.id}:0"
      )
    end

    it "flags a non-idempotent orphaned started row needs_review, with a reason, and stops the run" do
      stub_const("ExecutorSpecNonIdempotentWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } } # no idempotent: true
      end)
      run = build_run(workflow_class: ExecutorSpecNonIdempotentWorkflow)
      step = simulate_crashed_step(run)

      expect { described_class.new(run).call }
        .to raise_error(Belay::Error, /#{step.id}.*position 0.*crash.*extract.*idempotent: true/)

      # Nothing retried: still exactly the one row, now flagged rather than left started.
      expect(run.steps.where(position: 0).count).to eq(1)
      step.reload
      expect(step.status).to eq("needs_review")
      expect(step.error["reason"]).to match(/#{step.id}.*position 0.*crash.*extract.*idempotent: true/)
      expect(run.reload.status).to eq("paused") # not failed/cancelled, and distinguishable from still-running
    end

    it "treats idempotent: \"false\" (a string, not the boolean) as NOT idempotent, not as truthy" do
      stub_const("ExecutorSpecStringIdempotentWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract, idempotent: "false") { |ctx| { total_cents: ctx.invoice_id * 100 } }
      end)
      run = build_run(workflow_class: ExecutorSpecStringIdempotentWorkflow)
      simulate_crashed_step(run)

      expect { described_class.new(run).call }.to raise_error(Belay::Error, /idempotent: true/)
      expect(run.steps.find_by(position: 0).status).to eq("needs_review")
    end

    it "raises rather than silently re-processing a step already flagged needs_review on a later resume" do
      stub_const("ExecutorSpecAlreadyNeedsReviewWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      end)
      run = build_run(workflow_class: ExecutorSpecAlreadyNeedsReviewWorkflow)
      simulate_crashed_step(run)
      begin
        described_class.new(run).call # flags needs_review, raises
      rescue Belay::Error
        nil
      end

      expect { described_class.new(run).call }
        .to raise_error(Belay::Error, /position 0 is needs_review/)
    end

    it "does not require idempotent: true for a step's normal first execution - only for resuming a crash" do
      stub_const("ExecutorSpecFreshNonIdempotentWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } } # no idempotent: true, no existing row
      end)
      run = build_run(workflow_class: ExecutorSpecFreshNonIdempotentWorkflow)

      described_class.new(run).call

      expect(run.steps.find_by(position: 0).status).to eq("succeeded")
    end
  end

  describe "calling it twice on the same run" do
    it "is a no-op the second time: no error, no duplicate rows, no step block re-invoked" do
      extract_calls = 0
      stub_const("ExecutorSpecRepeatWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) do |ctx|
          extract_calls += 1
          { total_cents: ctx.invoice_id * 100 }
        end
      end)
      run = build_run(workflow_class: ExecutorSpecRepeatWorkflow)

      described_class.new(run).call
      described_class.new(run).call

      expect(extract_calls).to eq(1)
      expect(run.steps.count).to eq(1)
    end

    it "deep-symbolizes a skipped step's output, so a later block's symbol-key access sees what a fresh run sees" do
      # Simulates a crash exactly between extract committing and verify ever getting a
      # started row: extract already checkpointed, string-keyed exactly as Postgres
      # would actually return it, nothing else touched yet.
      run = build_run
      Belay::Step.create!(
        run: run, position: 0, name: "extract", kind: "decision", status: "succeeded",
        output: { "total_cents" => 4200 }, idempotency_key: "#{run.id}:0"
      )

      described_class.new(run).call

      # verify's block does ctx.extract[:total_cents].positive? - if extract's reused
      # output weren't symbolized, [:total_cents] would be nil and this would raise
      # NoMethodError on nil, not produce this value.
      expect(run.steps.find_by(position: 1).output).to eq(true)
    end

    it "re-runs an orphaned started row in place, without creating a duplicate row or bumping attempt" do
      stub_const("ExecutorSpecOrphanedIdempotentWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract, idempotent: true) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      end)
      run = build_run(workflow_class: ExecutorSpecOrphanedIdempotentWorkflow)
      Belay::Step.create!(
        run: run, position: 0, name: "extract", kind: "decision", status: "started",
        idempotency_key: "#{run.id}:0"
      )

      described_class.new(run).call

      extract_rows = run.steps.where(position: 0)
      expect(extract_rows.count).to eq(1)
      expect(extract_rows.first.status).to eq("succeeded")
      expect(extract_rows.first.attempt).to eq(1)
      expect(extract_rows.first.output).to eq("total_cents" => 4200)
    end

    %w[failed needs_review].each do |status|
      it "raises rather than silently re-running a step already left #{status}" do
        run = build_run
        step = Belay::Step.create!(
          run: run, position: 0, name: "extract", kind: "decision", status: status,
          idempotency_key: "#{run.id}:0"
        )

        expect { described_class.new(run).call }
          .to raise_error(Belay::Error, /#{step.id}.*position 0.*#{status}/)
      end
    end
  end

  describe "gates" do
    def gate_workflow(condition, **gate_options)
      Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
        gate(:approval, when: condition, **gate_options)
        step(:book) { |_ctx| "booked" }
      end
    end

    it "checkpoints a gate as skipped when: false, with no output, and the run completes past it" do
      stub_const("ExecutorSpecGateFalseWorkflow", gate_workflow(->(_ctx) { false }))
      run = build_run(workflow_class: ExecutorSpecGateFalseWorkflow)

      described_class.new(run).call

      gate_step = run.steps.find_by(position: 1)
      expect(gate_step).to have_attributes(status: "skipped", kind: "gate", output: nil)
      expect(run.reload.status).to eq("completed")
      expect(run.steps.find_by(position: 2).status).to eq("succeeded") # :book still ran
    end

    it "evaluates when: with the step's own context, including a prior step's output" do
      stub_const("ExecutorSpecGateContextWorkflow", gate_workflow(->(ctx) { ctx.extract[:total_cents] > 100_00 }))
      # invoice_id: 200 -> extract's 200 * 100 = 20000 cents, well over the 10000 threshold
      run = build_run(workflow_class: ExecutorSpecGateContextWorkflow, input: { invoice_id: 200 })

      # when: evaluated true here (20000 > 10000), which isn't supported yet - raises,
      # same as the dedicated "evaluates true" test below. Confirms real ctx access
      # (ctx.extract's actual value), not just a stubbed condition.
      expect { described_class.new(run).call }.to raise_error(Belay::Error, /evaluated true/)

      expect(run.steps.find_by(position: 1).status).to eq("failed")
      expect(run.steps.where(position: 2)).to be_empty
    end

    it "raises a clear, not-yet-implemented error when when: evaluates true - pausing for a human isn't built yet" do
      stub_const("ExecutorSpecGateTrueWorkflow", gate_workflow(->(_ctx) { true }))
      run = build_run(workflow_class: ExecutorSpecGateTrueWorkflow)

      expect { described_class.new(run).call }
        .to raise_error(Belay::Error, /approval.*evaluated true.*isn't implemented yet/)

      gate_step = run.steps.find_by(position: 1)
      expect(gate_step).to have_attributes(status: "failed", kind: "gate")
      expect(run.reload.status).to eq("running") # never reaches complete! - the raise propagates out
    end

    it "resumes past an already-skipped gate without calling when: again" do
      calls = 0
      stub_const("ExecutorSpecGateResumeWorkflow", gate_workflow(lambda { |_ctx|
        calls += 1
        false
      }))
      run = build_run(workflow_class: ExecutorSpecGateResumeWorkflow)
      Belay::Step.create!(run: run, position: 1, name: "approval", kind: "gate", status: "skipped",
                          output: nil, idempotency_key: "#{run.id}:1")

      described_class.new(run).call

      expect(calls).to eq(0) # never invoked - the existing skipped row was reused as-is
      expect(run.reload.status).to eq("completed")
    end

    it "re-evaluates when: once per attempt under retries:, same as a step's block would be re-run" do
      calls = 0
      stub_const("ExecutorSpecGateRetriesWorkflow", gate_workflow(lambda { |_ctx|
        calls += 1
        true
      }, retries: 2))
      run = build_run(workflow_class: ExecutorSpecGateRetriesWorkflow)

      expect { described_class.new(run).call }.to raise_error(Belay::Error, /evaluated true/)

      # retries: 2 means 3 attempts total (1 + 2), each its own row, each re-calling
      # when: - nothing here special-cases a gate to call it only once regardless of
      # retries:, documented on evaluate_gate! in executor.rb.
      expect(calls).to eq(3)
      expect(run.steps.where(position: 1).count).to eq(3)
    end
  end

  describe "a workflow name that doesn't resolve" do
    it "raises a Belay::Error naming the run and the bad constant, not a raw NameError" do
      run = build_run
      run.update_column(:workflow, "NotARealConstant")

      expect { described_class.new(run).call }.to raise_error(Belay::Error, /#{run.id}.*NotARealConstant/)
    end
  end
end
