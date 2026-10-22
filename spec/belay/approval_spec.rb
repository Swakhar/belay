# frozen_string_literal: true

RSpec.describe Belay::Approval do
  let(:run) { Belay::Run.create!(workflow: "InvoiceWorkflow", workflow_version: "v1") }
  let(:step) do
    Belay::Step.create!(run: run, position: 0, name: "approval", kind: "gate", status: "started",
                        idempotency_key: "k0")
  end

  def build_approval(**attrs)
    described_class.create!({ run: run, step: step }.merge(attrs))
  end

  describe "persistence" do
    it "requires a run, via the model's own optional: false, not host app config" do
      approval = described_class.new(step: step)

      expect { approval.save! }.to raise_error(ActiveRecord::RecordInvalid, /Run must exist/)
    end

    it "requires a step, via the model's own optional: false, not host app config" do
      approval = described_class.new(run: run)

      expect { approval.save! }.to raise_error(ActiveRecord::RecordInvalid, /Step must exist/)
    end

    it "requires run_id and step_id at the DB level too, independent of the model validations above" do
      approval = described_class.new

      expect { approval.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "requires a run and step that actually exist, enforced by the DB foreign keys" do
      approval = described_class.new(run_id: SecureRandom.uuid, step_id: SecureRandom.uuid)

      expect { approval.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "defaults status to pending" do
      expect(build_approval.status).to eq("pending")
    end

    it "rejects an explicit nil status with a validation error, not a raw DB error" do
      expect { build_approval(status: nil) }.to raise_error(ActiveRecord::RecordInvalid, /Status/)
    end

    it "belongs to the run and step it was created with" do
      approval = build_approval

      expect(approval.run).to eq(run)
      expect(approval.step).to eq(step)
      expect(run.approvals).to include(approval)
      expect(step.approval).to eq(approval)
    end

    it "rejects a second approval for the same step, enforced by the DB unique index on step_id" do
      build_approval

      expect { build_approval }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "defaults decided_by, decided_at and edited_payload to nil" do
      approval = build_approval

      expect(approval.decided_by).to be_nil
      expect(approval.decided_at).to be_nil
      expect(approval.edited_payload).to be_nil
    end
  end

  describe "status enum" do
    it "accepts each of the three declared statuses" do
      %w[pending approved rejected].each_with_index do |status, i|
        step_for_status = Belay::Step.create!(run: run, position: i, name: "g-#{status}", kind: "gate",
                                              status: "started", idempotency_key: "k-#{status}")
        # described_class.create! directly, not build_approval: its default hash
        # literal {run: run, step: step}.merge(attrs) evaluates the memoized `step`
        # let eagerly even when attrs overrides it afterward, creating a Step at
        # position: 0 on this same run - colliding with step_for_status's own
        # position: 0 on the first iteration via belay_steps' unique index on
        # [run_id, position, attempt], not an approvals-table collision.
        approval = described_class.create!(run: run, step: step_for_status, status: status)
        expect(approval.status).to eq(status)
      end
    end

    it "raises immediately on an unknown status" do
      expect { build_approval(status: "not_a_real_status") }.to raise_error(ArgumentError)
    end
  end

  it "has no approve!/reject! of its own - that's Run's job, a later commit" do
    expect(described_class.instance_methods(false)).not_to include(:approve!, :reject!)
  end
end
