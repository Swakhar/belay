# frozen_string_literal: true

RSpec.describe Belay::GeminiProvider do
  def build_provider(**attrs)
    described_class.new(api_key: "test-key", **attrs)
  end

  def stub_gemini(status:, body:, matching: anything)
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    allow(Net::HTTP).to receive(:post).with(anything, matching, anything).and_return(response)
    response
  end

  def sent_body(&block)
    satisfy("matching body") { |json| block.call(JSON.parse(json)) }
  end

  describe "#initialize" do
    it "raises a clear error when no api_key is available, from the constructor or GEMINI_API_KEY" do
      expect { described_class.new(api_key: nil) }.to raise_error(ArgumentError, /api_key/)
    end
  end

  describe "#call" do
    it "sends the api_key as a ?key= query param on the model-specific URL, not a header" do
      provider = build_provider(api_key: "secret-key")
      body = { candidates: [{ content: { parts: [{ text: "x" }] } }], usageMetadata: {} }
      response = instance_double(Net::HTTPResponse, code: "200", body: JSON.generate(body))
      expect(Net::HTTP).to receive(:post).with(
        URI("https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro:generateContent?key=secret-key"),
        anything, anything
      ).and_return(response)

      provider.call(model: "gemini-3-pro", prompt: "hi")
    end

    it "sends contents and generationConfig.maxOutputTokens, with no responseSchema when schema: is omitted" do
      provider = build_provider(max_output_tokens: 2048)
      expected_body = {
        "contents" => [{ "parts" => [{ "text" => "what is the answer?" }] }],
        "generationConfig" => { "maxOutputTokens" => 2048 }
      }
      stub_gemini(status: 200, body: { candidates: [{ content: { parts: [{ text: "x" }] } }], usageMetadata: {} },
                  matching: sent_body { |b| b == expected_body })

      provider.call(model: "gemini-3-pro", prompt: "what is the answer?")
    end

    it "adds responseMimeType and responseSchema when schema: is present" do
      provider = build_provider
      schema = { "type" => "OBJECT", "properties" => { "total_cents" => { "type" => "INTEGER" } } }
      matcher = satisfy("matching body") do |json|
        body = JSON.parse(json)
        body["generationConfig"]["responseMimeType"] == "application/json" &&
          body["generationConfig"]["responseSchema"] == schema
      end
      stub_gemini(status: 200, body: {
                    candidates: [{ content: { parts: [{ text: '{"total_cents":4200}' }] } }], usageMetadata: {}
                  }, matching: matcher)

      provider.call(model: "gemini-3-pro", prompt: "extract", schema: schema)
    end

    it "returns the text part as a ProviderResponse when no schema: was given" do
      provider = build_provider
      stub_gemini(status: 200, body: {
                    modelVersion: "gemini-3-pro-001", candidates: [{ content: { parts: [{ text: "the answer" }] } }],
                    usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 }
                  })

      response = provider.call(model: "gemini-3-pro", prompt: "what is the answer?")

      expect(response).to be_a(Belay::ProviderResponse)
      expect(response.content).to eq("the answer")
      expect(response.model).to eq("gemini-3-pro-001")
      expect(response.input_tokens).to eq(10)
      expect(response.output_tokens).to eq(5)
    end

    it "parses the text part as JSON when schema: is given" do
      provider = build_provider
      stub_gemini(status: 200, body: {
                    candidates: [{ content: { parts: [{ text: '{"total_cents":4200}' }] }, finishReason: "STOP" }],
                    usageMetadata: {}
                  })

      response = provider.call(model: "gemini-3-pro", prompt: "extract", schema: { type: "OBJECT" })

      expect(response.content).to eq("total_cents" => 4200)
    end

    it "raises StructuredOutputError with reason: refusal when finishReason is SAFETY" do
      provider = build_provider
      stub_gemini(status: 200, body: { candidates: [{ content: {}, finishReason: "SAFETY" }], usageMetadata: {} })

      expect { provider.call(model: "gemini-3-pro", prompt: "extract", schema: { type: "OBJECT" }) }
        .to raise_error(Belay::GeminiProvider::StructuredOutputError) { |e| expect(e.reason).to eq("refusal") }
    end

    it "raises StructuredOutputError with reason: refusal when finishReason is RECITATION" do
      provider = build_provider
      stub_gemini(status: 200, body: { candidates: [{ content: {}, finishReason: "RECITATION" }], usageMetadata: {} })

      expect { provider.call(model: "gemini-3-pro", prompt: "extract", schema: { type: "OBJECT" }) }
        .to raise_error(Belay::GeminiProvider::StructuredOutputError) { |e| expect(e.reason).to eq("refusal") }
    end

    it "raises StructuredOutputError with reason: max_tokens when finishReason is MAX_TOKENS" do
      provider = build_provider
      stub_gemini(status: 200, body: {
                    candidates: [{ content: { parts: [{ text: '{"total_cen' }] }, finishReason: "MAX_TOKENS" }],
                    usageMetadata: {}
                  })

      expect { provider.call(model: "gemini-3-pro", prompt: "extract", schema: { type: "OBJECT" }) }
        .to raise_error(Belay::GeminiProvider::StructuredOutputError) { |e| expect(e.reason).to eq("max_tokens") }
    end

    it "computes cost_cents from usage and a supplied pricing table" do
      pricing = { "gemini-3-pro" => { input_per_million: 1.25, output_per_million: 5.0 } }
      provider = build_provider(pricing: pricing)
      stub_gemini(status: 200, body: {
                    candidates: [{ content: { parts: [{ text: "x" }] } }],
                    usageMetadata: { promptTokenCount: 1_000_000, candidatesTokenCount: 1_000_000 }
                  })

      response = provider.call(model: "gemini-3-pro", prompt: "hi")

      expect(response.cost_cents).to eq(625) # ($1.25 + $5) * 100 cents
    end

    it "leaves cost_cents nil when no pricing is supplied for the model" do
      provider = build_provider
      stub_gemini(status: 200, body: {
                    candidates: [{ content: { parts: [{ text: "x" }] } }],
                    usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5 }
                  })

      response = provider.call(model: "gemini-3-pro", prompt: "hi")

      expect(response.cost_cents).to be_nil
    end

    it "raises a clear error when the response has no text part and no schema: was given" do
      provider = build_provider
      stub_gemini(status: 200, body: { candidates: [{ content: { parts: [] } }], usageMetadata: {} })

      expect { provider.call(model: "gemini-3-pro", prompt: "hi") }.to raise_error(Belay::Error, /text/)
    end

    it "raises RequestError with the status and body on a non-2xx response" do
      provider = build_provider
      stub_gemini(status: 429, body: { error: { code: 429, message: "slow down", status: "RESOURCE_EXHAUSTED" } })

      expect { provider.call(model: "gemini-3-pro", prompt: "hi") }
        .to raise_error(Belay::GeminiProvider::RequestError, /429.*RESOURCE_EXHAUSTED/m)
    end
  end
end
