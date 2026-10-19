# frozen_string_literal: true

RSpec.describe Belay::ResumeRunJob do
  before do
    stub_const("ResumeRunJobSpecWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
    end)
  end

  def build_run(input: { invoice_id: 42 })
    Belay::Run.create!(
      workflow: "ResumeRunJobSpecWorkflow",
      workflow_version: ResumeRunJobSpecWorkflow.workflow_version,
      input: input
    )
  end

  it "acquires the lease and runs the executor, completing the run" do
    run = build_run

    described_class.perform_now(run.id)

    expect(run.reload.status).to eq("completed")
    expect(run.steps.sole.output).to eq("total_cents" => 4200)
  end

  it "claims the lease using its own job_id as the owner" do
    run = build_run
    job = described_class.new(run.id)

    job.perform_now

    expect(run.reload.lease_owner).to eq(job.job_id)
  end

  it "quietly does nothing if the run is already leased by someone else, rather than erroring or forcing in" do
    run = build_run
    run.acquire_lease!(owner: "some-other-worker", duration: 300)

    expect { described_class.perform_now(run.id) }.not_to raise_error

    expect(run.reload.status).to eq("pending") # never got to start! - the executor never ran
    expect(run.steps.count).to eq(0)
  end

  it "proceeds once the existing lease has expired, even if some other owner once held it" do
    run = build_run
    run.acquire_lease!(owner: "some-other-worker", duration: -1) # already expired

    described_class.perform_now(run.id)

    expect(run.reload.status).to eq("completed")
  end

  it "raises ActiveRecord::RecordNotFound for a run id that doesn't exist, rather than failing silently" do
    expect { described_class.perform_now(SecureRandom.uuid) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "propagates an error the executor raises, rather than swallowing it" do
    stub_const("ResumeRunJobSpecRaisingWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:boom) { |_ctx| raise "step blew up" }
    end)
    run = Belay::Run.create!(
      workflow: "ResumeRunJobSpecRaisingWorkflow",
      workflow_version: ResumeRunJobSpecRaisingWorkflow.workflow_version,
      input: { invoice_id: 42 }
    )

    expect { described_class.perform_now(run.id) }.to raise_error(RuntimeError, "step blew up")
  end
end
