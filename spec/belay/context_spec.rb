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

  describe "#step_idempotency_key" do
    it "defaults to nil, so Context stays constructible standalone without one" do
      expect(described_class.new.step_idempotency_key).to be_nil
    end

    it "exposes whatever value it's constructed with, verbatim" do
      ctx = described_class.new(step_idempotency_key: "run-id:0")

      expect(ctx.step_idempotency_key).to eq("run-id:0")
    end

    it "is a plain reader, not dynamically served - an input/output named the same still collides" do
      expect { described_class.new(input: { step_idempotency_key: "sneaky" }) }
        .to raise_error(ArgumentError, /step_idempotency_key.*collide with an existing method/)
    end
  end

  describe "#llm" do
    after { Belay.reset_config! }

    it "raises a clear error when Belay.config.provider is not set" do
      ctx = described_class.new

      expect { ctx.llm(model: "claude-sonnet-5-5", prompt: "hi") }
        .to raise_error(Belay::Error, /Belay\.config\.provider is not set/)
    end

    it "calls the configured provider and returns its content" do
      Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: ["the answer"]) }
      ctx = described_class.new

      expect(ctx.llm(model: "claude-sonnet-5-5", prompt: "what is the answer?")).to eq("the answer")
    end

    it "passes model, prompt and schema through to the provider verbatim" do
      provider = Belay::FakeProvider.new(responses: [{ "total_cents" => 4200 }])
      Belay.configure { |c| c.provider = provider }
      ctx = described_class.new
      schema = { type: "object", properties: { total_cents: { type: "integer" } } }

      ctx.llm(model: "claude-sonnet-5-5", prompt: "extract", schema: schema)

      expect(provider.calls.sole).to eq(model: "claude-sonnet-5-5", prompt: "extract", schema: schema)
    end

    describe "schema validation" do
      let(:schema) do
        { "type" => "object", "properties" => { "total_cents" => { "type" => "integer" } },
          "required" => ["total_cents"] }
      end

      it "returns the content when it matches schema:" do
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [{ "total_cents" => 4200 }]) }
        ctx = described_class.new

        expect(ctx.llm(model: "x", prompt: "extract", schema: schema)).to eq("total_cents" => 4200)
      end

      it "raises SchemaValidationError when the provider's content doesn't match schema:" do
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [{ "total_cents" => "not an integer" }]) }
        ctx = described_class.new

        expect { ctx.llm(model: "x", prompt: "extract", schema: schema) }
          .to raise_error(Belay::Context::SchemaValidationError, /total_cents/)
      end

      it "raises SchemaValidationError when a required field is missing" do
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [{}]) }
        ctx = described_class.new

        expect { ctx.llm(model: "x", prompt: "extract", schema: schema) }.to raise_error(Belay::Context::SchemaValidationError)
      end

      it "records llm_metadata before raising, not after - a billed call that fails validation still isn't lost" do
        response = Belay::ProviderResponse.new(content: {}, model: "claude-sonnet-5-5", cost_cents: 18)
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [response]) }
        ctx = described_class.new

        expect { ctx.llm(model: "x", prompt: "extract", schema: schema) }.to raise_error(Belay::Context::SchemaValidationError)
        expect(ctx.llm_metadata).to eq(provider: "Belay::FakeProvider", model: "claude-sonnet-5-5", input: "extract",
                                       input_tokens: nil, output_tokens: nil, cost_cents: 18, latency_ms: nil)
      end

      it "accepts a symbol-keyed schema, not just string-keyed" do
        symbol_schema = { type: "object", properties: { total_cents: { type: "integer" } }, required: [:total_cents] }
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [{ "total_cents" => 4200 }]) }
        ctx = described_class.new

        expect(ctx.llm(model: "x", prompt: "extract", schema: symbol_schema)).to eq("total_cents" => 4200)
      end

      it "validates a symbol-keyed content Hash against the schema, not just string-keyed" do
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [{ total_cents: 4200 }]) }
        ctx = described_class.new

        expect(ctx.llm(model: "x", prompt: "extract", schema: schema)).to eq(total_cents: 4200)
      end

      it "does not validate at all when schema: is omitted" do
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: ["not json at all"]) }
        ctx = described_class.new

        expect { ctx.llm(model: "x", prompt: "hi") }.not_to raise_error
      end

      it "exposes SchemaValidationError#errors as JSONSchemer's own validation error list" do
        Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [{}]) }
        ctx = described_class.new

        begin
          ctx.llm(model: "x", prompt: "extract", schema: schema)
        rescue Belay::Context::SchemaValidationError => e
          expect(e.errors).not_to be_empty
          expect(e.errors).to all(be_a(Hash))
        end
      end
    end
  end

  describe "#llm_metadata" do
    after { Belay.reset_config! }

    it "is {} before #llm has ever been called" do
      expect(described_class.new.llm_metadata).to eq({})
    end

    it "records provider, model, the prompt, tokens, cost and latency after a successful #llm call" do
      response = Belay::ProviderResponse.new(content: "x", model: "claude-sonnet-5-5", input_tokens: 10,
                                             output_tokens: 5, cost_cents: 18, latency_ms: 420)
      Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [response]) }
      ctx = described_class.new

      ctx.llm(model: "claude-sonnet-5-5", prompt: "hi")

      expect(ctx.llm_metadata).to eq(provider: "Belay::FakeProvider", model: "claude-sonnet-5-5", input: "hi",
                                     input_tokens: 10, output_tokens: 5, cost_cents: 18, latency_ms: 420)
    end

    it "records whatever prompt: was given verbatim, not a summary of it" do
      response = Belay::ProviderResponse.new(content: "x", model: "claude-sonnet-5-5")
      Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: [response]) }
      ctx = described_class.new

      ctx.llm(model: "claude-sonnet-5-5", prompt: "extract the total from this invoice")

      expect(ctx.llm_metadata[:input]).to eq("extract the total from this invoice")
    end

    it "returns a frozen Hash, so a caller can't corrupt what the executor later reads" do
      expect(described_class.new.llm_metadata).to be_frozen
    end
  end
end
