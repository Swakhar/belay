# frozen_string_literal: true

RSpec.describe Belay::Run do
  def build_run(**attrs)
    described_class.create!({ workflow: "InvoiceWorkflow", workflow_version: "v1" }.merge(attrs))
  end

  describe "#replay_of / #replays" do
    it "defaults to no replay_of, for an ordinary run" do
      run = build_run

      expect(run.replay_of).to be_nil
      expect(run.replays).to be_empty
    end

    it "associates a shadow run back to the original it was replayed from" do
      original = build_run
      shadow = build_run(replay_of: original, replay_model: "claude-opus-5-5")

      expect(shadow.replay_of).to eq(original)
      expect(original.replays).to eq([shadow])
      expect(shadow.replay_model).to eq("claude-opus-5-5")
    end
  end

  describe "persistence" do
    it "requires workflow and workflow_version" do
      expect { described_class.create!(workflow_version: "v1") }.to raise_error(ActiveRecord::RecordInvalid)
      expect { described_class.create!(workflow: "X") }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "defaults to pending with position 0 and an empty input" do
      run = build_run

      expect(run.status).to eq("pending")
      expect(run.current_position).to eq(0)
      expect(run.input).to eq({})
    end
  end

  describe "status enum" do
    it "exposes a predicate per status" do
      run = build_run

      expect(run.pending?).to be true
      expect(run.running?).to be false
    end

    it "raises immediately on an unknown status, not just at save" do
      run = build_run

      expect { run.status = "not_a_real_status" }.to raise_error(ArgumentError)
    end
  end

  describe "guarded transitions" do
    it "moves pending -> running on start!, stamping started_at" do
      run = build_run

      run.start!

      expect(run.status).to eq("running")
      expect(run.started_at).to be_present
    end

    it "moves running -> paused -> running via pause!/resume!" do
      run = build_run
      run.start!

      run.pause!
      expect(run.status).to eq("paused")

      run.resume!
      expect(run.status).to eq("running")
    end

    it "rejects resume! on a pending run, even though running is a legal target of start!" do
      run = build_run # pending, never started

      expect { run.resume! }.to raise_error(Belay::InvalidTransitionError, /pending/)
      expect(run.reload.status).to eq("pending")
    end

    it "rejects start! on a paused run, even though both start! and resume! target running" do
      run = build_run
      run.start!
      run.pause!

      expect { run.start! }.to raise_error(Belay::InvalidTransitionError, /paused/)
      expect(run.reload.status).to eq("paused")
    end

    it "moves running -> completed on complete!, stamping finished_at" do
      run = build_run
      run.start!

      run.complete!

      expect(run.status).to eq("completed")
      expect(run.finished_at).to be_present
    end

    it "moves running -> failed on fail!, recording the error" do
      run = build_run
      run.start!

      run.fail!(error: { "message" => "boom" })

      expect(run.status).to eq("failed")
      expect(run.finished_at).to be_present
      expect(run.error).to eq({ "message" => "boom" })
    end

    it "cancels from pending, running, or paused" do
      expect(build_run.tap(&:cancel!).status).to eq("cancelled")
      expect(build_run.tap(&:start!).tap(&:cancel!).status).to eq("cancelled")
      expect(build_run.tap(&:start!).tap(&:pause!).tap(&:cancel!).status).to eq("cancelled")
    end

    it "raises Belay::InvalidTransitionError for a disallowed transition" do
      run = build_run # pending

      expect { run.pause! }.to raise_error(Belay::InvalidTransitionError, /pending.*paused/)
      expect(run.reload.status).to eq("pending")
    end

    it "never allows a transition out of a terminal status" do
      run = build_run
      run.start!
      run.complete!

      expect { run.start! }.to raise_error(Belay::InvalidTransitionError)
      expect { run.cancel! }.to raise_error(Belay::InvalidTransitionError)
    end
  end

  describe "#acquire_lease!" do
    it "claims an unleased run, setting lease_owner and an expiry duration: in the future" do
      run = build_run
      frozen_now = Time.current
      allow(Time).to receive(:current).and_return(frozen_now)

      result = run.acquire_lease!(owner: "worker-1", duration: 300)

      expect(result).to be true
      expect(run.lease_owner).to eq("worker-1")
      expect(run.lease_expires_at).to be_within(1.second).of(frozen_now + 300)
    end

    it "reloads the record on a successful claim, reflecting what the conditional UPDATE actually wrote" do
      run = build_run

      run.acquire_lease!(owner: "worker-1", duration: 300)

      expect(run.reload.lease_owner).to eq("worker-1")
    end

    it "refuses to claim a run already leased by someone else, before that lease expires" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: 300)

      result = run.acquire_lease!(owner: "worker-2", duration: 300)

      expect(result).to be false
      expect(run.reload.lease_owner).to eq("worker-1")
    end

    it "allows reclaiming a run whose lease has already expired, by a different owner" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: -1) # already expired the moment it's set

      result = run.acquire_lease!(owner: "worker-2", duration: 300)

      expect(result).to be true
      expect(run.reload.lease_owner).to eq("worker-2")
    end

    it "does not let the SAME owner re-acquire its own still-valid lease - that's heartbeating, not acquiring" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: 300)
      original_expiry = run.reload.lease_expires_at

      result = run.acquire_lease!(owner: "worker-1", duration: 600)

      expect(result).to be false
      expect(run.reload.lease_expires_at).to eq(original_expiry) # unchanged - not extended
    end

    it "defaults duration: to Belay.config.lease_duration" do
      run = build_run
      frozen_now = Time.current
      allow(Time).to receive(:current).and_return(frozen_now)

      run.acquire_lease!(owner: "worker-1")

      expect(run.lease_expires_at).to be_within(1.second).of(frozen_now + Belay.config.lease_duration)
    end
  end

  describe "#heartbeat_lease!" do
    it "extends lease_expires_at for the current owner while the lease is still valid" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: 300)

      result = run.heartbeat_lease!(owner: "worker-1", duration: 300)

      expect(result).to be true
      new_expiry = run.reload.lease_expires_at
      expect(new_expiry).to be > Time.current + 290 # freshly extended, not the original ~300s window
    end

    it "succeeds at the exact instant the lease expires (>=), the precise complement of acquire's strict <" do
      # Two separate runs, both leased to expire at exactly the same frozen instant,
      # so testing one doesn't mutate the state the other is checked against.
      heartbeat_run = build_run
      reclaim_run = build_run
      frozen_now = Time.current
      allow(Time).to receive(:current).and_return(frozen_now)
      heartbeat_run.acquire_lease!(owner: "worker-1", duration: 0) # lease_expires_at == frozen_now, exactly
      reclaim_run.acquire_lease!(owner: "worker-1", duration: 0)

      # At this exact instant: heartbeat (>=) succeeds for the original owner, and a
      # second acquire (<) by someone else must NOT be able to reclaim it - the two
      # conditions must never both be true for the same timestamp.
      heartbeat_result = heartbeat_run.heartbeat_lease!(owner: "worker-1", duration: 300)
      reclaim_result = reclaim_run.acquire_lease!(owner: "worker-2", duration: 300)

      expect(heartbeat_result).to be true
      expect(reclaim_result).to be false
    end

    it "refuses to heartbeat a lease owned by someone else" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: 300)
      original_expiry = run.reload.lease_expires_at

      result = run.heartbeat_lease!(owner: "worker-2", duration: 300)

      expect(result).to be false
      expect(run.reload.lease_expires_at).to eq(original_expiry)
    end

    it "refuses to heartbeat a lease that's already expired, even for the original owner" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: -1) # already expired

      result = run.heartbeat_lease!(owner: "worker-1", duration: 300)

      expect(result).to be false
    end

    it "refuses to heartbeat a run that was never leased at all" do
      run = build_run

      result = run.heartbeat_lease!(owner: "worker-1", duration: 300)

      expect(result).to be false
    end

    it "defaults duration: to Belay.config.lease_duration" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: 300)
      frozen_now = Time.current
      allow(Time).to receive(:current).and_return(frozen_now)

      run.heartbeat_lease!(owner: "worker-1")

      expect(run.lease_expires_at).to be_within(1.second).of(frozen_now + Belay.config.lease_duration)
    end
  end

  describe "#release_lease!" do
    it "clears lease_owner and lease_expires_at" do
      run = build_run
      run.acquire_lease!(owner: "worker-1", duration: 300)

      result = run.release_lease!

      expect(result).to be true
      expect(run.lease_owner).to be_nil
      expect(run.lease_expires_at).to be_nil
      expect(run.reload.lease_owner).to be_nil
    end

    it "is unconditional, unlike acquire_lease!/heartbeat_lease! - clears even a lease it never held" do
      run = build_run
      run.acquire_lease!(owner: "someone-else", duration: 300)

      run.release_lease!

      expect(run.reload.lease_owner).to be_nil
    end

    it "is a no-op, not an error, on a run that was never leased at all" do
      run = build_run

      expect { run.release_lease! }.not_to raise_error
      expect(run.lease_owner).to be_nil
    end
  end

  describe "#pending_gate" do
    it "returns nil when the run has no awaiting_approval step" do
      run = build_run.tap(&:start!)
      run.steps.create!(position: 0, name: "extract", kind: "decision", status: "succeeded",
                        idempotency_key: "#{run.id}:0")

      expect(run.pending_gate).to be_nil
    end

    it "returns the step awaiting_approval" do
      run = build_run.tap(&:start!).tap(&:pause!)
      gate_step = run.steps.create!(position: 0, name: "approval", kind: "gate", status: "awaiting_approval",
                                    idempotency_key: "#{run.id}:0")

      expect(run.pending_gate).to eq(gate_step)
    end
  end

  # Both methods below need a run genuinely paused on a gate (not just hand-built
  # rows): build_paused_run runs InvoiceWorkflow-shaped gate for real, through the
  # actual evaluate_gate! path, so these specs exercise approve!/reject! against the
  # exact state that pausing a run for real leaves behind - same reasoning as
  # executor_spec.rb's own gate specs.
  def build_paused_run
    stub_const("RunSpecGateWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      gate(:approval, when: ->(_ctx) { true })
      step(:book) { |ctx| { booked: true, approval_payload: ctx.approval } }
    end)
    run = described_class.create!(
      workflow: "RunSpecGateWorkflow", workflow_version: RunSpecGateWorkflow.workflow_version,
      input: { invoice_id: 42 }
    )
    Belay::Executor.new(run).call
    run.reload
  end

  describe "#approve!" do
    it "raises if the run has no pending gate" do
      run = build_run.tap(&:start!)

      expect { run.approve!(by: "reviewer@example.com") }.to raise_error(Belay::Error, /no pending gate/)
    end

    it "settles the gate succeeded, records an approved Approval, resumes the run and enqueues ResumeRunJob" do
      run = build_paused_run
      gate = run.pending_gate
      expect(Belay::ResumeRunJob).to receive(:perform_later).with(run.id)

      run.approve!(by: "reviewer@example.com")

      expect(gate.reload.status).to eq("succeeded")
      expect(gate.output).to be_nil # no edited_payload given - same as today's behavior
      approval = gate.approval
      expect(approval.status).to eq("approved")
      expect(approval.decided_by).to eq("reviewer@example.com")
      expect(approval.decided_at).to be_present
      expect(approval.edited_payload).to be_nil
      expect(run.reload.status).to eq("running")
    end

    it "uses edited_payload as the gate's own output, visible to later steps as ctx.<gate name>" do
      run = build_paused_run

      run.approve!(by: "reviewer@example.com", edited_payload: { total_cents: 999 })
      Belay::ResumeRunJob.perform_now(run.id)

      gate = run.steps.find_by(position: 1)
      expect(gate.output).to eq("total_cents" => 999)
      expect(run.approvals.sole.edited_payload).to eq("total_cents" => 999)
      book = run.steps.find_by(position: 2)
      expect(book.output).to eq("booked" => true, "approval_payload" => { "total_cents" => 999 })
    end

    it "leaves no pending_gate once approved" do
      run = build_paused_run

      run.approve!(by: "reviewer@example.com")

      expect(run.reload.pending_gate).to be_nil
    end

    it "actually resumes past the gate to the next step once the enqueued ResumeRunJob runs" do
      run = build_paused_run
      run.approve!(by: "reviewer@example.com")

      Belay::ResumeRunJob.perform_now(run.id)

      expect(run.reload.status).to eq("completed")
      expect(run.steps.where(position: 2).sole.output).to eq("booked" => true, "approval_payload" => nil)
    end

    it "raises a clean error, not a raw DB exception, when a racing call already decided this gate" do
      run = build_paused_run
      gate = run.pending_gate
      Belay::Approval.create!(run: run, step: gate, status: "approved", decided_by: "someone-else")

      expect { run.approve!(by: "reviewer@example.com") }
        .to raise_error(Belay::Error, /already decided/)
    end
  end

  describe "#reject!" do
    it "raises if the run has no pending gate" do
      run = build_run.tap(&:start!)

      expect { run.reject!(by: "reviewer@example.com") }.to raise_error(Belay::Error, /no pending gate/)
    end

    it "settles the gate failed, records a rejected Approval and fails the run outright, without enqueuing anything" do
      run = build_paused_run
      gate = run.pending_gate
      expect(Belay::ResumeRunJob).not_to receive(:perform_later)

      run.reject!(by: "reviewer@example.com")

      expect(gate.reload.status).to eq("failed")
      approval = gate.approval
      expect(approval.status).to eq("rejected")
      expect(approval.decided_by).to eq("reviewer@example.com")
      expect(run.reload.status).to eq("failed")
    end
  end

  # Exercises the real flag_needs_review! path (executor.rb) rather than hand-
  # building a needs_review row, same reasoning build_paused_run above gives for
  # gates: this proves resolve_needs_review! against the exact state a real
  # crash-and-resume leaves behind, not an approximation of it.
  def simulate_crashed_step(run)
    run.steps.create!(position: 0, name: "extract", kind: "decision", status: "started",
                      idempotency_key: "#{run.id}:0")
  end

  def build_run_with_needs_review # rubocop:disable Metrics/AbcSize
    stub_const("RunSpecNeedsReviewWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } } # no idempotent: true
      step(:book) { |ctx| { booked_total_cents: ctx.extract&.dig(:total_cents) } }
    end)
    run = described_class.create!(
      workflow: "RunSpecNeedsReviewWorkflow", workflow_version: RunSpecNeedsReviewWorkflow.workflow_version,
      input: { invoice_id: 42 }
    )
    simulate_crashed_step(run) # a non-idempotent step left "started" - simulates a crash mid-step
    expect { Belay::Executor.new(run).call }.to raise_error(Belay::Error, /needs_review|idempotent/)
    run.reload
  end

  describe "#pending_needs_review" do
    it "returns nil when the run has no needs_review step" do
      run = build_run.tap(&:start!)

      expect(run.pending_needs_review).to be_nil
    end

    it "returns the step flagged needs_review" do
      run = build_run_with_needs_review

      expect(run.pending_needs_review).to eq(run.steps.find_by(name: "extract"))
    end
  end

  describe "#resolve_needs_review!" do
    it "raises if the run has no needs_review step" do
      run = build_run.tap(&:start!)

      expect { run.resolve_needs_review!(by: "reviewer", outcome: "succeeded") }
        .to raise_error(Belay::Error, /no needs_review step/)
    end

    it "raises ArgumentError for an outcome that isn't succeeded or failed" do
      run = build_run_with_needs_review

      expect { run.resolve_needs_review!(by: "reviewer", outcome: "approved") }
        .to raise_error(ArgumentError, /succeeded.*failed/)
    end

    it "settles the step succeeded with the given output, resumes the run and enqueues ResumeRunJob" do
      run = build_run_with_needs_review
      step = run.pending_needs_review
      expect(Belay::ResumeRunJob).to receive(:perform_later).with(run.id)

      run.resolve_needs_review!(by: "reviewer@example.com", outcome: "succeeded", output: { total_cents: 4200 })

      step.reload
      expect(step.status).to eq("succeeded")
      expect(step.output).to eq("total_cents" => 4200)
      expect(step.resolved_by).to eq("reviewer@example.com")
      expect(step.resolved_at).to be_present
      expect(run.reload.status).to eq("running")
    end

    it "actually resumes past the step to the next one once the enqueued ResumeRunJob runs" do
      run = build_run_with_needs_review

      run.resolve_needs_review!(by: "reviewer", outcome: "succeeded", output: { total_cents: 4200 })
      Belay::ResumeRunJob.perform_now(run.id)

      expect(run.reload.status).to eq("completed")
      expect(run.steps.find_by(name: "book").output).to eq("booked_total_cents" => 4200)
    end

    it "settles the step failed and fails the run outright, without enqueuing anything" do
      run = build_run_with_needs_review
      step = run.pending_needs_review
      expect(Belay::ResumeRunJob).not_to receive(:perform_later)

      run.resolve_needs_review!(by: "reviewer@example.com", outcome: "failed")

      step.reload
      expect(step.status).to eq("failed")
      expect(step.resolved_by).to eq("reviewer@example.com")
      expect(run.reload.status).to eq("failed")
    end

    it "raises a clean error, not a silent overwrite, when a racing call already resolved this step" do
      run = build_run_with_needs_review
      step = run.pending_needs_review
      # Stubbed, not re-fetched: simulates this caller's in-memory read happening
      # BEFORE a second caller's write lands, same as a true race would - calling
      # pending_needs_review for real here would just see the already-succeeded
      # row and correctly report "no needs_review step to resolve" instead of
      # reaching the specific conditional-UPDATE path this test is about.
      allow(run).to receive(:pending_needs_review).and_return(step)
      step.update_columns(status: "succeeded") # the second caller actually won first

      expect { run.resolve_needs_review!(by: "reviewer", outcome: "failed") }
        .to raise_error(Belay::Error, /already resolved/)
      expect(step.reload.status).to eq("succeeded") # unchanged - not overwritten back to failed
    end
  end
end
