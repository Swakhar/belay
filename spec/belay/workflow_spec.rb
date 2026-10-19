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
