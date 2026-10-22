# frozen_string_literal: true

RSpec.describe Belay::Step do
  let(:run) { Belay::Run.create!(workflow: "InvoiceWorkflow", workflow_version: "v1") }

  def build_step(**attrs)
    described_class.create!({
      run: run, position: 0, name: "extract", kind: "llm_call", idempotency_key: "k0"
    }.merge(attrs))
  end

  describe "persistence" do
    it "requires position, name, kind and idempotency_key" do
      expect { described_class.create!(run: run, name: "x", kind: "llm_call", idempotency_key: "k") }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { described_class.create!(run: run, position: 0, kind: "llm_call", idempotency_key: "k") }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { described_class.create!(run: run, position: 0, name: "x", idempotency_key: "k") }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect { described_class.create!(run: run, position: 0, name: "x", kind: "llm_call") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it "requires a run, via the model's own optional: false, not host app config" do
      step = described_class.new(position: 0, name: "x", kind: "llm_call", idempotency_key: "k")

      expect { step.save! }.to raise_error(ActiveRecord::RecordInvalid, /Run must exist/)
    end

    it "requires a run_id at the DB level too, independent of the model validation above" do
      step = described_class.new(position: 0, name: "x", kind: "llm_call", idempotency_key: "k")

      expect { step.save!(validate: false) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "requires a run that actually exists, enforced by the DB foreign key" do
      step = described_class.new(run_id: SecureRandom.uuid, position: 0, name: "x", kind: "llm_call",
                                 idempotency_key: "k")

      expect { step.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "defaults status to started" do
      expect(build_step.status).to eq("started")
    end

    it "rejects an explicit nil status with a validation error, not a raw DB error" do
      expect { build_step(status: nil) }.to raise_error(ActiveRecord::RecordInvalid, /Status/)
    end

    it "belongs to the run it was created with" do
      step = build_step

      expect(step.run).to eq(run)
      expect(run.steps).to include(step)
    end
  end

  describe "kind enum" do
    it "accepts each of the four declared kinds" do
      %w[llm_call tool_call decision gate].each_with_index do |kind, i|
        expect(build_step(position: i, kind: kind, idempotency_key: "k-#{kind}").kind).to eq(kind)
      end
    end

    it "raises immediately on an unknown kind" do
      expect { build_step(kind: "not_a_real_kind") }.to raise_error(ArgumentError)
    end
  end

  describe "status enum" do
    it "accepts each of the six declared statuses" do
      %w[started succeeded failed skipped needs_review awaiting_approval].each_with_index do |status, i|
        expect(build_step(position: i, status: status, idempotency_key: "k-#{status}").status).to eq(status)
      end
    end

    it "raises immediately on an unknown status" do
      expect { build_step(status: "not_a_real_status") }.to raise_error(ArgumentError)
    end
  end

  it "allows the same idempotency_key to repeat across attempts at the same position" do
    first = build_step(attempt: 1, idempotency_key: "stable-key")
    second = build_step(attempt: 2, idempotency_key: "stable-key")

    expect(first.idempotency_key).to eq(second.idempotency_key)
  end

  it "rejects a second row at the same [run, position, attempt], enforced by the DB unique index" do
    build_step(attempt: 1)

    expect { build_step(attempt: 1, idempotency_key: "different-key") }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
