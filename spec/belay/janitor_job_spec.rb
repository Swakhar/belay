# frozen_string_literal: true

RSpec.describe Belay::JanitorJob do
  before do
    stub_const("JanitorJobSpecWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
    end)
  end

  def build_run(status: :running, **attrs)
    run = Belay::Run.create!(
      workflow: "JanitorJobSpecWorkflow",
      workflow_version: JanitorJobSpecWorkflow.workflow_version,
      input: { invoice_id: 42 },
      **attrs
    )
    run.start! if %i[running paused].include?(status)
    run.pause! if status == :paused
    run
  end

  it "re-enqueues a running run whose lease has expired" do
    run = build_run
    run.acquire_lease!(owner: "dead-worker", duration: -1)

    expect(Belay::ResumeRunJob).to receive(:perform_later).with(run.id)

    described_class.perform_now
  end

  it "re-enqueues a running run that was never leased at all" do
    run = build_run # never leased - e.g. crashed mid Workflow.start's inline execution

    expect(Belay::ResumeRunJob).to receive(:perform_later).with(run.id)

    described_class.perform_now
  end

  it "leaves a running run alone while its lease is still live" do
    run = build_run
    run.acquire_lease!(owner: "live-worker", duration: 300)

    expect(Belay::ResumeRunJob).not_to receive(:perform_later)

    described_class.perform_now
  end

  it "leaves a paused run alone even if it was once leased and that lease expired" do
    run = build_run(status: :paused)
    run.acquire_lease!(owner: "dead-worker", duration: -1)

    expect(Belay::ResumeRunJob).not_to receive(:perform_later)

    described_class.perform_now
  end

  it "leaves pending, completed, failed and cancelled runs alone" do
    pending_run = build_run(status: :pending)
    completed_run = build_run.tap(&:complete!)
    failed_run = build_run.tap { |r| r.fail!(error: { "message" => "boom" }) }
    cancelled_run = build_run.tap(&:cancel!)
    [pending_run, completed_run, failed_run, cancelled_run].each do |run|
      run.update_columns(lease_owner: "dead-worker", lease_expires_at: 1.hour.ago)
    end

    expect(Belay::ResumeRunJob).not_to receive(:perform_later)

    described_class.perform_now
  end

  it "re-enqueues each stale run once when there are several" do
    stale_one = build_run
    stale_two = build_run

    expect(Belay::ResumeRunJob).to receive(:perform_later).with(stale_one.id)
    expect(Belay::ResumeRunJob).to receive(:perform_later).with(stale_two.id)

    described_class.perform_now
  end
end
