# frozen_string_literal: true

RSpec.describe Belay::OpenAIProvider do
  def build_provider(**attrs)
    described_class.new(api_key: "test-key", **attrs)
  end

  def stub_openai(url:, status:, body:, matching: anything)
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    allow(Net::HTTP).to receive(:post).with(url, matching, anything).and_return(response)
    response
  end

  def sent_body(&block)
    satisfy("matching body") { |json| block.call(JSON.parse(json)) }
  end

  describe "#initialize" do
    it "raises a clear error when no api_key is available, from the constructor or OPENAI_API_KEY" do
      expect { described_class.new(api_key: nil) }.to raise_error(ArgumentError, /api_key/)
    end

    it "raises a clear error when api: is neither :responses nor :chat_completions" do
      expect { build_provider(api: :legacy_completions) }.to raise_error(ArgumentError, /api:/)
    end
  end

  describe "#call with api: :responses (the default)" do
    def responses_url
      Belay::OpenAIProvider::API_URLS.fetch(:responses)
    end

    it "sends the Authorization header" do
      provider = build_provider(api_key: "secret-key")
      body = { output: [{ type: "message", content: [{ type: "output_text", text: "x" }] }], usage: {} }
      response = instance_double(Net::HTTPResponse, code: "200", body: JSON.generate(body))
      expect(Net::HTTP).to receive(:post)
        .with(responses_url, anything, hash_including("Authorization" => "Bearer secret-key"))
        .and_return(response)

      provider.call(model: "gpt-5.1", prompt: "hi")
    end

    it "sends model and input as the prompt, with no text.format when schema: is omitted" do
      provider = build_provider
      stub_openai(url: responses_url, status: 200,
                  body: { output: [{ type: "message", content: [{ type: "output_text", text: "x" }] }], usage: {} },
                  matching: sent_body do |b|
                    b == { "model" => "gpt-5.1", "input" => "hi", "max_output_tokens" => 4096 }
                  end)

      provider.call(model: "gpt-5.1", prompt: "hi")
    end

    it "adds text.format: json_schema with the given schema, strict: true, when schema: is present" do
      provider = build_provider
      schema = { "type" => "object", "properties" => { "total_cents" => { "type" => "integer" } } }
      expected_format = { "type" => "json_schema", "name" => "belay_response", "schema" => schema, "strict" => true }
      stub_openai(url: responses_url, status: 200, body: {
                    output: [{ type: "message", content: [{ type: "output_text", text: '{"total_cents":4200}' }] }],
                    usage: {}
                  }, matching: sent_body { |b| b["text"]["format"] == expected_format })

      provider.call(model: "gpt-5.1", prompt: "extract", schema: schema)
    end

    it "returns the output_text as a ProviderResponse when no schema: was given" do
      provider = build_provider
      stub_openai(url: responses_url, status: 200, body: {
                    model: "gpt-5.1",
                    output: [{ type: "message", content: [{ type: "output_text", text: "the answer" }] }],
                    usage: { input_tokens: 10, output_tokens: 5 }
                  })

      response = provider.call(model: "gpt-5.1", prompt: "what is the answer?")

      expect(response).to be_a(Belay::ProviderResponse)
      expect(response.content).to eq("the answer")
      expect(response.input_tokens).to eq(10)
      expect(response.output_tokens).to eq(5)
    end

    it "parses the output_text as JSON when schema: is given" do
      provider = build_provider
      stub_openai(url: responses_url, status: 200, body: {
                    output: [{ type: "message", content: [{ type: "output_text", text: '{"total_cents":4200}' }] }],
                    usage: {}
                  })

      response = provider.call(model: "gpt-5.1", prompt: "extract", schema: { type: "object" })

      expect(response.content).to eq("total_cents" => 4200)
    end

    it "raises StructuredOutputError with reason: refusal when a refusal content item is present" do
      provider = build_provider
      stub_openai(url: responses_url, status: 200, body: {
                    output: [{ type: "message", content: [{ type: "refusal", refusal: "I can't do that" }] }], usage: {}
                  })

      expect { provider.call(model: "gpt-5.1", prompt: "extract", schema: { type: "object" }) }
        .to raise_error(Belay::OpenAIProvider::StructuredOutputError) { |e| expect(e.reason).to eq("refusal") }
    end

    it "raises StructuredOutputError with reason: max_tokens when incomplete for max_output_tokens" do
      provider = build_provider
      stub_openai(url: responses_url, status: 200, body: {
                    status: "incomplete", incomplete_details: { reason: "max_output_tokens" },
                    output: [{ type: "message", content: [{ type: "output_text", text: '{"total_cen' }] }], usage: {}
                  })

      expect { provider.call(model: "gpt-5.1", prompt: "extract", schema: { type: "object" }) }
        .to raise_error(Belay::OpenAIProvider::StructuredOutputError) { |e| expect(e.reason).to eq("max_tokens") }
    end

    it "raises RequestError with the status and body on a non-2xx response" do
      provider = build_provider
      stub_openai(url: responses_url, status: 429, body: { error: { type: "rate_limit_error", message: "slow down" } })

      expect { provider.call(model: "gpt-5.1", prompt: "hi") }
        .to raise_error(Belay::OpenAIProvider::RequestError, /429.*rate_limit_error/m)
    end
  end

  describe "#call with api: :chat_completions" do
    def chat_url
      Belay::OpenAIProvider::API_URLS.fetch(:chat_completions)
    end

    it "sends model, max_completion_tokens and the prompt as a user message" do
      provider = build_provider(api: :chat_completions, max_tokens: 2048)
      expected_body = {
        "model" => "gpt-5.1", "max_completion_tokens" => 2048,
        "messages" => [{ "role" => "user", "content" => "what is the answer?" }]
      }
      stub_openai(url: chat_url, status: 200,
                  body: { choices: [{ message: { content: "x" }, finish_reason: "stop" }], usage: {} },
                  matching: sent_body { |b| b == expected_body })

      provider.call(model: "gpt-5.1", prompt: "what is the answer?")
    end

    it "adds response_format: json_schema with the given schema, strict: true, when schema: is present" do
      provider = build_provider(api: :chat_completions)
      schema = { "type" => "object", "properties" => { "total_cents" => { "type" => "integer" } } }
      expected_json_schema = { "name" => "belay_response", "schema" => schema, "strict" => true }
      stub_openai(url: chat_url, status: 200,
                  body: {
                    choices: [{ message: { content: '{"total_cents":4200}' }, finish_reason: "stop" }], usage: {}
                  }, matching: sent_body { |b| b["response_format"]["json_schema"] == expected_json_schema })

      provider.call(model: "gpt-5.1", prompt: "extract", schema: schema)
    end

    it "returns the message content as a ProviderResponse when no schema: was given" do
      provider = build_provider(api: :chat_completions)
      stub_openai(url: chat_url, status: 200, body: {
                    model: "gpt-5.1", choices: [{ message: { content: "the answer" }, finish_reason: "stop" }],
                    usage: { prompt_tokens: 10, completion_tokens: 5 }
                  })

      response = provider.call(model: "gpt-5.1", prompt: "what is the answer?")

      expect(response.content).to eq("the answer")
      expect(response.input_tokens).to eq(10)
      expect(response.output_tokens).to eq(5)
    end

    it "raises StructuredOutputError with reason: refusal when message.refusal is present" do
      provider = build_provider(api: :chat_completions)
      stub_openai(url: chat_url, status: 200, body: {
                    choices: [{ message: { content: nil, refusal: "I can't do that" },
                                finish_reason: "stop" }], usage: {}
                  })

      expect { provider.call(model: "gpt-5.1", prompt: "extract", schema: { type: "object" }) }
        .to raise_error(Belay::OpenAIProvider::StructuredOutputError) { |e| expect(e.reason).to eq("refusal") }
    end

    it "raises StructuredOutputError with reason: max_tokens when finish_reason is length" do
      provider = build_provider(api: :chat_completions)
      stub_openai(url: chat_url, status: 200, body: {
                    choices: [{ message: { content: '{"total_cen' }, finish_reason: "length" }], usage: {}
                  })

      expect { provider.call(model: "gpt-5.1", prompt: "extract", schema: { type: "object" }) }
        .to raise_error(Belay::OpenAIProvider::StructuredOutputError) { |e| expect(e.reason).to eq("max_tokens") }
    end

    it "computes cost_cents from usage and a supplied pricing table" do
      pricing = { "gpt-5.1" => { input_per_million: 2.0, output_per_million: 8.0 } }
      provider = build_provider(api: :chat_completions, pricing: pricing)
      stub_openai(url: chat_url, status: 200, body: {
                    choices: [{ message: { content: "x" }, finish_reason: "stop" }],
                    usage: { prompt_tokens: 1_000_000, completion_tokens: 1_000_000 }
                  })

      response = provider.call(model: "gpt-5.1", prompt: "hi")

      expect(response.cost_cents).to eq(1000) # ($2 + $8) * 100 cents
    end
  end
end
