# frozen_string_literal: true

RSpec.describe Belay::Context do
  describe "exposing input" do
    it "exposes an input value as a dotted method call" do
      ctx = described_class.new(input: { invoice_id: 42 })

      expect(ctx.invoice_id).to eq(42)
    end

    it "accepts string keys, symbolizing them so dotted access still works" do
      ctx = described_class.new(input: { "invoice_id" => 42 })

      expect(ctx.invoice_id).to eq(42)
    end
  end

  describe "exposing prior step outputs" do
    it "exposes a prior step's output as a dotted method call" do
      ctx = described_class.new(outputs: { extract: { total_cents: 10_000 } })

      expect(ctx.extract).to eq(total_cents: 10_000)
    end
  end

  it "raises NoMethodError for a name that's neither a declared input nor a prior output" do
    ctx = described_class.new(input: { invoice_id: 42 })

    expect { ctx.not_a_real_thing }.to raise_error(NoMethodError)
  end

  it "raises ArgumentError at construction if an input and an output share a name" do
    expect { described_class.new(input: { extract: 1 }, outputs: { extract: 2 }) }
      .to raise_error(ArgumentError, /collide.*extract/)
  end

  it "raises ArgumentError if an input/output name collides with a real method (class, hash, input, ...)" do
    expect { described_class.new(input: { class: "oops" }) }
      .to raise_error(ArgumentError, /class.*collide with an existing method/)
    expect { described_class.new(outputs: { hash: 123 }) }
      .to raise_error(ArgumentError, /hash.*collide with an existing method/)
    expect { described_class.new(input: { input: "oops" }) }
      .to raise_error(ArgumentError, /input.*collide with an existing method/)
  end

  it "raises ArgumentError if two keys collapse to the same symbol" do
    expect { described_class.new(input: { "invoice_id" => 1, invoice_id: 2 }) }
      .to raise_error(ArgumentError, /collapse to the same name/)
  end

  it "raises NoMethodError, not silently ignoring the block, when called with one" do
    ctx = described_class.new(input: { invoice_id: 42 })

    expect { ctx.invoice_id { "ignored?" } }.to raise_error(NoMethodError)
  end

  describe "#respond_to?" do
    it "is true for a declared input and a prior output, false for anything else" do
      ctx = described_class.new(input: { invoice_id: 42 }, outputs: { extract: {} })

      expect(ctx.respond_to?(:invoice_id)).to be true
      expect(ctx.respond_to?(:extract)).to be true
      expect(ctx.respond_to?(:not_a_real_thing)).to be false
    end
  end

  describe "#input and #outputs" do
    it "return the full hashes, frozen" do
      ctx = described_class.new(input: { invoice_id: 42 }, outputs: { extract: {} })

      expect(ctx.input).to eq(invoice_id: 42)
      expect(ctx.outputs).to eq(extract: {})
      expect(ctx.input).to be_frozen
      expect(ctx.outputs).to be_frozen
    end
  end

  it "is frozen itself, once constructed" do
    expect(described_class.new).to be_frozen
  end
end
