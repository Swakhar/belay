# frozen_string_literal: true

RSpec.describe Belay::Workflow do
  def workflow_class(&block)
    Class.new(described_class, &block)
  end

  describe ".input" do
    it "records declared names as symbols, accepting multiple at once" do
      klass = workflow_class { input :invoice_id, "customer_id" }

      expect(klass.inputs).to eq(%i[invoice_id customer_id])
    end

    it "raises on a duplicate input name" do
      expect do
        workflow_class do
          input :invoice_id
          input :invoice_id
        end
      end.to raise_error(ArgumentError, /invoice_id.*already declared/)
    end
  end

  describe ".step" do
    it "requires a block" do
      expect { workflow_class { step :extract } }.to raise_error(ArgumentError, /needs a block/)
    end

    it "preserves declaration order" do
      klass = workflow_class do
        step(:extract) { |ctx| ctx }
        step(:verify) { |ctx| ctx }
        step(:book) { |ctx| ctx }
      end

      expect(klass.steps.map(&:name)).to eq(%i[extract verify book])
    end

    it "raises on a duplicate step name" do
      expect do
        workflow_class do
          step(:extract) { |ctx| ctx }
          step(:extract) { |ctx| ctx }
        end
      end.to raise_error(ArgumentError, /extract.*already declared/)
    end

    it "captures arbitrary options verbatim, without interpreting them" do
      klass = workflow_class do
        step(:book, idempotent: true, retries: 3) { |ctx| ctx }
      end

      expect(klass.steps.first.options).to eq(idempotent: true, retries: 3)
    end

    it "stores the block, callable later with a context argument" do
      klass = workflow_class do
        step(:extract) { |ctx| ctx * 2 }
      end

      expect(klass.steps.first.block.call(21)).to eq(42)
    end
  end

  describe ".gate" do
    it "raises when when: is missing" do
      expect { workflow_class { gate :approval } }.to raise_error(ArgumentError, /approval.*needs when:/)
    end

    it "raises when when: doesn't respond to #call" do
      expect { workflow_class { gate :approval, when: true } }.to raise_error(ArgumentError, /approval.*needs when:/)
    end

    it "records kind: :gate, not nil, with no block" do
      klass = workflow_class { gate :approval, when: ->(ctx) { ctx.total > 100 } }

      gate = klass.steps.first
      expect(gate.kind).to eq(:gate)
      expect(gate.block).to be_nil
    end

    it "captures when: inside options, callable later with a context argument" do
      klass = workflow_class { gate :approval, when: ->(ctx) { ctx > 100 } }

      expect(klass.steps.first.options[:when].call(150)).to be true
    end

    it "raises if kind: is also passed - a gate's kind is not the caller's to set" do
      expect { workflow_class { gate :approval, when: -> { true }, kind: "tool_call" } }
        .to raise_error(ArgumentError, /must not pass kind:/)
    end

    it "shares one ordered list with step - preserves declaration order across both" do
      klass = workflow_class do
        step(:extract) { |ctx| ctx }
        gate(:approval, when: -> { true })
        step(:book) { |ctx| ctx }
      end

      expect(klass.steps.map(&:name)).to eq(%i[extract approval book])
      expect(klass.steps.map(&:kind)).to eq([nil, :gate, nil])
    end

    it "raises on a duplicate name shared with a step, not just with another gate" do
      expect do
        workflow_class do
          step(:approval) { |ctx| ctx }
          gate(:approval, when: -> { true })
        end
      end.to raise_error(ArgumentError, /approval.*already declared/)
    end

    it "raises on a duplicate gate name" do
      expect do
        workflow_class do
          gate(:approval, when: -> { true })
          gate(:approval, when: -> { true })
        end
      end.to raise_error(ArgumentError, /approval.*already declared/)
    end
  end

  it "keeps each subclass's declarations independent" do
    invoice = workflow_class { step(:extract) { |ctx| ctx } }
    refund = workflow_class { step(:validate) { |ctx| ctx } }

    expect(invoice.steps.map(&:name)).to eq([:extract])
    expect(refund.steps.map(&:name)).to eq([:validate])
  end

  it "does not inherit a superclass workflow's declarations - not class_attribute, a plain ivar" do
    base = workflow_class { step(:a) { |ctx| ctx } }
    child = Class.new(base)

    expect(child.steps).to eq([])
    expect(base.steps.map(&:name)).to eq([:a]) # base is unaffected by child existing
  end

  describe ".step kind:" do
    it "defaults to nil when not given" do
      klass = workflow_class { step(:extract) { |ctx| ctx } }

      expect(klass.steps.first.kind).to be_nil
    end

    it "is stored as a symbol, separate from options" do
      klass = workflow_class { step(:book, kind: "decision", idempotent: true) { |ctx| ctx } }

      expect(klass.steps.first.kind).to eq(:decision)
      expect(klass.steps.first.options).to eq(idempotent: true)
    end

    it "raises a clear error for a kind that isn't a String, Symbol, or nil" do
      expect { workflow_class { step(:extract, kind: 1) { |ctx| ctx } } }
        .to raise_error(ArgumentError, /kind:.*String, Symbol, or nil/)
    end
  end

  describe ".workflow_version" do
    it "is a stable hex digest - the same class produces the same version every call" do
      klass = workflow_class { step(:extract) { |ctx| ctx } }

      expect(klass.workflow_version).to eq(klass.workflow_version)
      expect(klass.workflow_version).to match(/\A[0-9a-f]{64}\z/)
    end

    it "is the same for two classes with identical name/kind/order, even with different block bodies" do
      a = workflow_class do
        step(:extract, kind: :llm_call) { |ctx| ctx }
        step(:verify, kind: :decision, &:upcase)
      end
      b = workflow_class do
        step(:extract, kind: :llm_call) { |_ctx| raise "totally different body" }
        step(:verify, kind: :decision) { |_ctx| 42 }
      end

      expect(a.workflow_version).to eq(b.workflow_version)
    end

    it "changes when a step's name changes" do
      a = workflow_class { step(:extract) { |ctx| ctx } }
      b = workflow_class { step(:fetch) { |ctx| ctx } }

      expect(a.workflow_version).not_to eq(b.workflow_version)
    end

    it "changes when a step's kind changes" do
      a = workflow_class { step(:extract, kind: :llm_call) { |ctx| ctx } }
      b = workflow_class { step(:extract, kind: :tool_call) { |ctx| ctx } }

      expect(a.workflow_version).not_to eq(b.workflow_version)
    end

    it "changes when a step becomes a gate of the same name - no special-casing needed, kind: already covers it" do
      a = workflow_class { step(:approval) { |ctx| ctx } }
      b = workflow_class { gate(:approval, when: -> { true }) }

      expect(a.workflow_version).not_to eq(b.workflow_version)
    end

    it "does not change when only a gate's when: condition changes - not yet part of the fingerprint" do
      a = workflow_class { gate(:approval, when: -> { true }) }
      b = workflow_class { gate(:approval, when: -> { false }) }

      expect(a.workflow_version).to eq(b.workflow_version)
    end

    it "changes when the order of two steps is swapped" do
      a = workflow_class do
        step(:extract) { |ctx| ctx }
        step(:verify) { |ctx| ctx }
      end
      b = workflow_class do
        step(:verify) { |ctx| ctx }
        step(:extract) { |ctx| ctx }
      end

      expect(a.workflow_version).not_to eq(b.workflow_version)
    end

    it "does not change when only a step's options change (not yet part of the fingerprint)" do
      a = workflow_class { step(:book, idempotent: true) { |ctx| ctx } }
      b = workflow_class { step(:book, idempotent: false, retries: 3) { |ctx| ctx } }

      expect(a.workflow_version).to eq(b.workflow_version)
    end

    it "changes when the declared inputs change, even if the steps are identical" do
      a = workflow_class do
        input :invoice_id
        step(:extract) { |ctx| ctx }
      end
      b = workflow_class do
        input :invoice_id, :customer_id
        step(:extract) { |ctx| ctx }
      end

      expect(a.workflow_version).not_to eq(b.workflow_version)
    end
  end

  describe ".start" do
    def defined_workflow_class(name, &block)
      stub_const(name, Class.new(described_class, &block))
    end

    it "creates and executes a run, returning it" do
      klass = defined_workflow_class("WorkflowSpecStart") do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      end

      run = klass.start(invoice_id: 42, idempotency_key: "wf-start-1")

      expect(run).to be_a(Belay::Run)
      expect(run.workflow).to eq("WorkflowSpecStart")
      expect(run.workflow_version).to eq(klass.workflow_version)
      expect(run.input).to eq("invoice_id" => 42)
      expect(run.status).to eq("completed")
      expect(run.steps.sole.output).to eq("total_cents" => 4200)
    end

    it "deduplicates on idempotency_key: calling it twice returns the same run and never re-executes" do
      calls = 0
      klass = defined_workflow_class("WorkflowSpecDedup") do
        input :invoice_id
        step(:extract) do |ctx|
          calls += 1
          { total_cents: ctx.invoice_id * 100 }
        end
      end

      first = klass.start(invoice_id: 42, idempotency_key: "wf-dedup-1")
      second = klass.start(invoice_id: 999, idempotency_key: "wf-dedup-1") # different input, same key

      expect(second).to eq(first)
      expect(calls).to eq(1)
      expect(Belay::Run.where(idempotency_key: "wf-dedup-1").count).to eq(1)
    end

    it "returns the existing run on a repeat key even if this call's own input is invalid - no input needed twice" do
      klass = defined_workflow_class("WorkflowSpecDedupBadInput") do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      end
      first = klass.start(invoice_id: 42, idempotency_key: "wf-dedup-badinput-1")

      # Missing invoice_id entirely this time - would fail validate_input! on its own,
      # but the dedup lookup finds the existing run before validation ever runs.
      second = klass.start(idempotency_key: "wf-dedup-badinput-1")

      expect(second).to eq(first)
    end

    it "works for a workflow with no declared inputs at all" do
      klass = defined_workflow_class("WorkflowSpecNoInputs") do
        step(:extract) { |_ctx| "done" }
      end

      run = klass.start(idempotency_key: "wf-no-inputs-1")

      expect(run.status).to eq("completed")
      expect(run.input).to eq({})
    end

    it "raises a clear error rather than Run's own presence validation if the workflow class has no name" do
      anonymous_klass = Class.new(described_class) do
        input :invoice_id
        step(:extract) { |ctx| ctx }
      end

      expect { anonymous_klass.start(invoice_id: 42, idempotency_key: "wf-anon-1") }
        .to raise_error(Belay::Error, /must be assigned to a constant/)
    end

    it "raises ArgumentError for a missing required input" do
      klass = defined_workflow_class("WorkflowSpecMissingInput") do
        input :invoice_id, :customer_id
        step(:extract) { |ctx| ctx }
      end

      expect { klass.start(invoice_id: 42, idempotency_key: "wf-missing-1") }
        .to raise_error(ArgumentError, /missing required input.*customer_id/)
    end

    it "raises ArgumentError for an undeclared input" do
      klass = defined_workflow_class("WorkflowSpecExtraInput") do
        input :invoice_id
        step(:extract) { |ctx| ctx }
      end

      expect { klass.start(invoice_id: 42, extra_thing: 1, idempotency_key: "wf-extra-1") }
        .to raise_error(ArgumentError, /undeclared input.*extra_thing/)
    end

    it "raises if the same idempotency_key already belongs to a different workflow" do
      defined_workflow_class("WorkflowSpecOwnerA") do
        input :invoice_id
        step(:extract) { |ctx| ctx }
      end
      klass_b = defined_workflow_class("WorkflowSpecOwnerB") do
        input :invoice_id
        step(:extract) { |ctx| ctx }
      end
      WorkflowSpecOwnerA.start(invoice_id: 1, idempotency_key: "wf-shared-key")

      expect { klass_b.start(invoice_id: 1, idempotency_key: "wf-shared-key") }
        .to raise_error(Belay::Error, /wf-shared-key.*WorkflowSpecOwnerA.*WorkflowSpecOwnerB/)
    end

    it "returns the existing run, without executing it again, if create! loses the race to another caller" do
      klass = defined_workflow_class("WorkflowSpecRace") do
        input :invoice_id
        step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      end
      # The run some OTHER caller already committed - this one's find_by (below) will
      # be made to miss it once, simulating the race window between that commit and
      # this call's own lookup.
      winner = klass.start(invoice_id: 42, idempotency_key: "wf-race-1")

      calls = 0
      allow(Belay::Run).to receive(:find_by).and_wrap_original do |original, *args|
        calls += 1
        calls == 1 ? nil : original.call(*args)
      end

      loser_result = klass.start(invoice_id: 42, idempotency_key: "wf-race-1")

      expect(loser_result).to eq(winner)
      expect(Belay::Run.where(idempotency_key: "wf-race-1").count).to eq(1)
    end

    # Executor-level gate behavior (skip on false, not-yet-implemented error on
    # true, resume reusing a skipped row) has its own dedicated coverage in
    # executor_spec.rb's "gates" describe block - this just confirms .start wires a
    # gate-containing workflow through to the real executor at all, end to end.
    it "runs a gate through to a real skip via .start, end to end" do
      klass = defined_workflow_class("WorkflowSpecGateIntegration") do
        input :invoice_id
        gate(:approval, when: ->(_ctx) { false })
      end

      run = klass.start(invoice_id: 42, idempotency_key: "wf-gate-1")

      expect(run.status).to eq("completed")
      expect(run.steps.sole).to have_attributes(status: "skipped", kind: "gate")
    end
  end

  describe "immutability of what .inputs/.steps return" do
    it "returns a frozen array from .inputs, so a caller can't bypass the duplicate check" do
      klass = workflow_class { input :invoice_id }

      expect { klass.inputs << :sneaked_in }.to raise_error(FrozenError)
      expect(klass.inputs).to eq([:invoice_id]) # unaffected by the attempt above
    end

    it "returns a frozen array from .steps, and a frozen StepDefinition inside it" do
      klass = workflow_class { step(:extract) { |ctx| ctx } }

      expect { klass.steps << :sneaked_in }.to raise_error(FrozenError)
      expect { klass.steps.first.block = nil }.to raise_error(FrozenError)
      expect { klass.steps.first.options[:new_key] = 1 }.to raise_error(FrozenError)
    end
  end
end
