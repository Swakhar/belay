# frozen_string_literal: true

RSpec.describe Belay::Run do
  def build_run(**attrs)
    described_class.create!({ workflow: "InvoiceWorkflow", workflow_version: "v1" }.merge(attrs))
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
end
