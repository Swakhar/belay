# frozen_string_literal: true

RSpec.describe Belay::AnthropicProvider do
  def build_provider(**attrs)
    described_class.new(api_key: "test-key", **attrs)
  end

  # Stubs Net::HTTP.post itself (the real seam #perform_request calls), not
  # #perform_request - so #request_body and #request_headers, the actual
  # production code that shapes what gets sent, run for real in every spec below
  # and can be asserted on via the matcher: argument, not bypassed.
  def stub_anthropic(status:, body:, matching: anything)
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    allow(Net::HTTP).to receive(:post)
      .with(Belay::AnthropicProvider::API_URL, matching, anything)
      .and_return(response)
    response
  end

  def sent_body(&block)
    satisfy("matching body") { |json| block.call(JSON.parse(json)) }
  end

  describe "#initialize" do
    it "raises a clear error when no api_key is available, from the constructor or ANTHROPIC_API_KEY" do
      expect { described_class.new(api_key: nil) }.to raise_error(ArgumentError, /api_key/)
    end

    it "accepts an explicit api_key" do
      expect { described_class.new(api_key: "explicit-key") }.not_to raise_error
    end
  end

  describe "#call" do
    it "sends the right headers, including the api_key and anthropic-version" do
      provider = build_provider(api_key: "secret-key")
      body = JSON.generate({ content: [{ type: "text", text: "x" }], usage: {} })
      response = instance_double(Net::HTTPResponse, code: "200", body: body)
      expect(Net::HTTP).to receive(:post).with(
        Belay::AnthropicProvider::API_URL, anything,
        { "x-api-key" => "secret-key", "anthropic-version" => "2023-06-01", "content-type" => "application/json" }
      ).and_return(response)

      provider.call(model: "claude-sonnet-5-5", prompt: "hi")
    end

    it "sends model, max_tokens and the prompt as a user message, with no output_config when schema: is omitted" do
      provider = build_provider(max_tokens: 2048)
      expected_body = {
        "model" => "claude-sonnet-5-5", "max_tokens" => 2048,
        "messages" => [{ "role" => "user", "content" => "what is the answer?" }]
      }
      stub_anthropic(status: 200, body: { content: [{ type: "text", text: "x" }], usage: {} },
                     matching: sent_body { |b| b == expected_body })

      provider.call(model: "claude-sonnet-5-5", prompt: "what is the answer?")
    end

    it "adds output_config.format: json_schema with the given schema when schema: is present" do
      provider = build_provider
      schema = { "type" => "object", "properties" => { "total_cents" => { "type" => "integer" } } }
      expected_output_config = { "format" => { "type" => "json_schema", "schema" => schema } }
      stub_anthropic(status: 200, body: { content: [{ type: "text", text: '{"total_cents":4200}' }], usage: {} },
                     matching: sent_body { |b| b["output_config"] == expected_output_config })

      provider.call(model: "claude-sonnet-5-5", prompt: "extract", schema: schema)
    end

    it "returns the text content as a ProviderResponse when no schema: was given" do
      provider = build_provider
      stub_anthropic(status: 200, body: {
                       model: "claude-sonnet-5-5", content: [{ type: "text", text: "the answer" }],
                       usage: { input_tokens: 10, output_tokens: 5 }
                     })

      response = provider.call(model: "claude-sonnet-5-5", prompt: "what is the answer?")

      expect(response).to be_a(Belay::ProviderResponse)
      expect(response.content).to eq("the answer")
      expect(response.model).to eq("claude-sonnet-5-5")
      expect(response.input_tokens).to eq(10)
      expect(response.output_tokens).to eq(5)
    end

    it "records latency_ms as a non-negative integer" do
      provider = build_provider
      stub_anthropic(status: 200,
                     body: { model: "claude-sonnet-5-5", content: [{ type: "text", text: "x" }], usage: {} })

      response = provider.call(model: "claude-sonnet-5-5", prompt: "hi")

      expect(response.latency_ms).to be_a(Integer)
      expect(response.latency_ms).to be >= 0
    end

    it "computes cost_cents from usage and a supplied pricing table" do
      pricing = { "claude-sonnet-5-5" => { input_per_million: 3.0, output_per_million: 15.0 } }
      provider = build_provider(pricing: pricing)
      stub_anthropic(status: 200, body: {
                       model: "claude-sonnet-5-5", content: [{ type: "text", text: "x" }],
                       usage: { input_tokens: 1_000_000, output_tokens: 1_000_000 }
                     })

      response = provider.call(model: "claude-sonnet-5-5", prompt: "hi")

      expect(response.cost_cents).to eq(1800) # ($3 + $15) * 100 cents
    end

    it "leaves cost_cents nil when no pricing is supplied for the model" do
      provider = build_provider # pricing: {} by default
      stub_anthropic(status: 200, body: {
                       model: "claude-sonnet-5-5", content: [{ type: "text", text: "x" }],
                       usage: { input_tokens: 10, output_tokens: 5 }
                     })

      response = provider.call(model: "claude-sonnet-5-5", prompt: "hi")

      expect(response.cost_cents).to be_nil
    end

    it "parses the text block as JSON and returns it as a Hash when schema: is given" do
      provider = build_provider
      stub_anthropic(status: 200, body: {
                       model: "claude-sonnet-5-5", content: [{ type: "text", text: '{"total_cents":4200}' }],
                       usage: { input_tokens: 10, output_tokens: 5 }, stop_reason: "end_turn"
                     })

      response = provider.call(model: "claude-sonnet-5-5", prompt: "extract the total", schema: { type: "object" })

      expect(response.content).to eq("total_cents" => 4200)
    end

    it "raises StructuredOutputError with reason: refusal when Claude declines to match the schema" do
      provider = build_provider
      stub_anthropic(status: 200, body: {
                       content: [{ type: "text", text: "I can't do that" }], usage: {}, stop_reason: "refusal"
                     })

      expect { provider.call(model: "claude-sonnet-5-5", prompt: "extract", schema: { type: "object" }) }
        .to raise_error(Belay::AnthropicProvider::StructuredOutputError) { |e| expect(e.reason).to eq("refusal") }
    end

    it "raises StructuredOutputError with reason: max_tokens rather than parsing possibly-truncated JSON" do
      provider = build_provider
      stub_anthropic(status: 200, body: {
                       content: [{ type: "text", text: '{"total_cen' }], usage: {}, stop_reason: "max_tokens"
                     })

      expect { provider.call(model: "claude-sonnet-5-5", prompt: "extract", schema: { type: "object" }) }
        .to raise_error(Belay::AnthropicProvider::StructuredOutputError) { |e| expect(e.reason).to eq("max_tokens") }
    end

    it "raises a clear error when the response has no text block and no schema: was given" do
      provider = build_provider
      stub_anthropic(status: 200, body: { model: "claude-sonnet-5-5", content: [], usage: {} })

      expect { provider.call(model: "claude-sonnet-5-5", prompt: "hi") }.to raise_error(Belay::Error, /text/)
    end

    it "raises RequestError with the status and body on a non-2xx response" do
      provider = build_provider
      stub_anthropic(status: 429, body: { error: { type: "rate_limit_error", message: "slow down" } })

      expect { provider.call(model: "claude-sonnet-5-5", prompt: "hi") }
        .to raise_error(Belay::AnthropicProvider::RequestError, /429.*rate_limit_error/m)
    end

    it "exposes the failed response's status on RequestError" do
      provider = build_provider
      stub_anthropic(status: 500, body: { error: { type: "api_error", message: "internal error" } })

      begin
        provider.call(model: "claude-sonnet-5-5", prompt: "hi")
      rescue Belay::AnthropicProvider::RequestError => e
        expect(e.status).to eq(500)
      end
    end
  end
end
