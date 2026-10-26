# frozen_string_literal: true

RSpec.describe Belay::Rule do
  def identity(context_key: "k1")
    { workflow: "InvoiceWorkflow", workflow_version: "v1", gate_name: "approval", context_key: context_key }
  end

  describe ".context_key_for" do
    it "is the same for identical input/outputs" do
      a = described_class.context_key_for(input: { invoice_id: 42 }, outputs: { extract: { total_cents: 4200 } })
      b = described_class.context_key_for(input: { invoice_id: 42 }, outputs: { extract: { total_cents: 4200 } })

      expect(a).to eq(b)
    end

    it "differs on input or outputs" do
      base = described_class.context_key_for(input: { invoice_id: 42 }, outputs: {})

      expect(described_class.context_key_for(input: { invoice_id: 43 }, outputs: {})).not_to eq(base)
      expect(described_class.context_key_for(input: { invoice_id: 42 }, outputs: { a: 1 })).not_to eq(base)
    end
  end

  describe ".record_approval!" do
    it "creates a new rule, still learning, with one consistent approval" do
      rule = described_class.record_approval!(**identity, threshold: 3)

      expect(rule).to have_attributes(status: "learning", consistent_approvals: 1)
    end

    it "accumulates consistent_approvals across calls for the same identity, not a sibling row" do
      described_class.record_approval!(**identity, threshold: 3)
      described_class.record_approval!(**identity, threshold: 3)

      expect(described_class.count).to eq(1)
      expect(described_class.sole.consistent_approvals).to eq(2)
    end

    it "becomes active once consistent_approvals reaches the threshold" do
      2.times { described_class.record_approval!(**identity, threshold: 2) }

      expect(described_class.sole).to have_attributes(status: "active", consistent_approvals: 2)
    end

    it "does not raise when the row was already created by a racing caller just before this one tries " \
       "to create it too - two different runs can legitimately hit the exact same context_key at once" do
      # The real DB-level unique index is what actually raises RecordNotUnique here
      # (no stubbing needed) - this is exactly the race create_or_find_by! guards
      # against: by the time record_approval! tries to create the row, it already
      # exists, same as if a second process had just won that race a moment ago.
      described_class.create!(**identity)

      expect { described_class.record_approval!(**identity, threshold: 3) }.not_to raise_error
      expect(described_class.count).to eq(1)
      expect(described_class.sole.consistent_approvals).to eq(1)
    end

    it "keeps separate rows for different gate occurrences (different context_key)" do
      described_class.record_approval!(**identity(context_key: "k1"), threshold: 3)
      described_class.record_approval!(**identity(context_key: "k2"), threshold: 3)

      expect(described_class.count).to eq(2)
      expect(described_class.pluck(:consistent_approvals)).to eq([1, 1])
    end

    it "never advances or re-activates a rule that's already invalidated" do
      described_class.record_rejection!(**identity)

      3.times { described_class.record_approval!(**identity, threshold: 1) }

      rule = described_class.sole
      expect(rule.status).to eq("invalidated")
      expect(rule.consistent_approvals).to eq(0)
    end
  end

  describe ".record_rejection!" do
    it "creates a new rule directly as invalidated, so it can never be learned from scratch for this context" do
      rule = described_class.record_rejection!(**identity)

      expect(rule).to have_attributes(status: "invalidated")
      expect(rule.invalidated_at).to be_present
    end

    it "invalidates a rule that was already learning or active" do
      described_class.record_approval!(**identity, threshold: 1) # already active

      rule = described_class.record_rejection!(**identity)

      expect(rule.status).to eq("invalidated")
    end

    it "is idempotent - rejecting an already-invalidated rule again doesn't raise" do
      described_class.record_rejection!(**identity)

      expect { described_class.record_rejection!(**identity) }.not_to raise_error
      expect(described_class.count).to eq(1)
    end
  end
end
