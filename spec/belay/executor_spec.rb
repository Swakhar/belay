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

  it "writes a stable idempotency_key of run_id:position for each step" do
    run = build_run

    described_class.new(run).call

    steps = run.steps.order(:position).to_a
    expect(steps.map(&:idempotency_key)).to eq(
      ["#{run.id}:0", "#{run.id}:1", "#{run.id}:2"]
    )
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
    it "propagates the error, leaving a started row (not succeeded, not missing) for the step that raised" do
      stub_const("ExecutorSpecRaisingWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
        step(:boom) { |_ctx| raise "step blew up" }
      end)
      run = build_run(workflow_class: ExecutorSpecRaisingWorkflow)

      expect { described_class.new(run).call }.to raise_error(RuntimeError, "step blew up")

      steps = run.steps.order(:position).index_by(&:name)
      expect(steps["extract"].status).to eq("succeeded")
      expect(steps["boom"].status).to eq("started")
      expect(steps["boom"].output).to be_nil
      expect(run.reload.status).to eq("running") # start! ran; complete! never got the chance to
    end
  end

  describe "calling it twice on the same run" do
    it "currently raises RecordNotUnique on the first step - no skip-logic yet (that's the next commit)" do
      run = build_run
      described_class.new(run).call

      expect { described_class.new(run).call }.to raise_error(ActiveRecord::RecordNotUnique)
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
