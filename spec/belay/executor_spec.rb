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

  describe "a step block that raises" do
    it "propagates the error and leaves no checkpoint for the step that raised" do
      stub_const("ExecutorSpecRaisingWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
        step(:boom) { |_ctx| raise "step blew up" }
      end)
      run = build_run(workflow_class: ExecutorSpecRaisingWorkflow)

      expect { described_class.new(run).call }.to raise_error(RuntimeError, "step blew up")
      expect(run.steps.pluck(:name)).to eq(["extract"])
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
