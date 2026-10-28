# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Belay
  # Calls Google's Gemini API directly over Net::HTTP (stdlib) - same
  # reasoning as AnthropicProvider/OpenAIProvider: no SDK gem, so no second
  # gem's own version matrix for this gem to track for a provider this
  # central.
  #
  # Endpoint and field names verified against Google's own REST reference
  # (ai.google.dev/api/generate-content) as of 2026-10-28.
  #
  # The API key goes in the request URL's own ?key= query param, not a
  # header - that's Gemini's own convention, unlike Anthropic's x-api-key or
  # OpenAI's Authorization: Bearer. URI.encode_www_form escapes it rather
  # than interpolating it directly into the URL string, purely so a key
  # containing a URL-meaningful character (unlikely, but API keys are
  # opaque strings this gem didn't generate) can't corrupt the request line.
  #
  # schema: is passed through to generationConfig.responseSchema completely
  # unvalidated and untranslated - Gemini's schema dialect uses its own,
  # UPPERCASE type names ("OBJECT", "STRING", "INTEGER", ...), not standard
  # JSON Schema's lowercase ones ("object", "string"), and doesn't support
  # every JSON Schema keyword. A schema written for AnthropicProvider or
  # OpenAIProvider will not work here unchanged - same spirit as
  # AnthropicProvider's additionalProperties: false requirement, just a
  # different provider-specific dialect. See docs/providers.md.
  #
  # finishReason is mapped to the same StructuredOutputError reason: values
  # the other two providers use, so a caller can branch on reason: the same
  # way regardless of which provider is configured: "SAFETY"/"RECITATION"
  # (the model declined to produce matching content) -> "refusal";
  # "MAX_TOKENS" -> "max_tokens". Like AnthropicProvider/OpenAIProvider, this
  # check only runs when schema: was given - see OpenAIProvider's own comment
  # for why a refusal/truncation on a plain-text call isn't this gem's call
  # to second-guess.
  class GeminiProvider < Provider
    API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"

    # Raised on any non-2xx response. Gemini's own error body (JSON, usually
    # {"error": {"code":, "message":, "status":}}) is preserved verbatim in
    # the message, same reasoning as AnthropicProvider::RequestError.
    class RequestError < Error
      attr_reader :status

      def initialize(status:, body:)
        @status = status
        super("Gemini API request failed with status #{status}: #{body}")
      end
    end

    # Raised when schema: was given but the response can't be trusted to
    # contain valid, complete schema-matching JSON. reason: is "refusal" or
    # "max_tokens" - see the class comment above for which finishReason maps
    # to each.
    class StructuredOutputError < Error
      attr_reader :reason, :response

      def initialize(reason:, response:)
        @reason = reason
        @response = response
        super("Gemini did not return schema-matching output (reason: #{reason.inspect}): #{response.inspect}")
      end
    end

    # pricing: {"gemini-..." => { input_per_million: <USD Float>, output_per_million: <USD Float> }, ...}
    # Deliberately not pre-filled with Google's current rates - same
    # reasoning as AnthropicProvider's own pricing: comment.
    def initialize(api_key: ENV.fetch("GEMINI_API_KEY", nil), max_output_tokens: 4096, pricing: {})
      super()
      raise ArgumentError, "#{self.class} requires api_key: (or GEMINI_API_KEY)" if api_key.nil?

      @api_key = api_key
      @max_output_tokens = max_output_tokens
      @pricing = pricing
    end

    def call(model:, prompt:, schema: nil)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, body = perform_request(model, request_body(prompt: prompt, schema: schema))
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      raise RequestError.new(status: status, body: body) unless status.between?(200, 299)

      build_response(JSON.parse(body), model: model, schema: schema, latency_ms: latency_ms)
    end

    private

    def request_body(prompt:, schema:)
      body = {
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { maxOutputTokens: @max_output_tokens }
      }
      return body if schema.nil?

      body[:generationConfig] = body[:generationConfig].merge(responseMimeType: "application/json",
                                                              responseSchema: schema)
      body
    end

    def perform_request(model, body)
      uri = URI("#{API_BASE}/#{model}:generateContent")
      uri.query = URI.encode_www_form(key: @api_key)
      response = Net::HTTP.post(uri, JSON.generate(body), { "content-type" => "application/json" })
      [response.code.to_i, response.body]
    end

    def build_response(response, model:, schema:, latency_ms:)
      usage = response["usageMetadata"] || {}
      input_tokens, output_tokens = usage.values_at("promptTokenCount", "candidatesTokenCount")

      ProviderResponse.new(
        content: extract_content(response, schema: schema),
        model: response["modelVersion"] || model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost_cents: cost_cents(model: model, input_tokens: input_tokens, output_tokens: output_tokens),
        latency_ms: latency_ms
      )
    end

    def extract_content(response, schema:)
      schema ? extract_structured_output(response) : extract_text(response)
    end

    def extract_structured_output(response)
      finish_reason = response.dig("candidates", 0, "finishReason")
      if %w[SAFETY RECITATION].include?(finish_reason)
        raise StructuredOutputError.new(reason: "refusal", response: response)
      end
      raise StructuredOutputError.new(reason: "max_tokens", response: response) if finish_reason == "MAX_TOKENS"

      JSON.parse(extract_text(response))
    end

    def extract_text(response)
      part = response.dig("candidates", 0, "content", "parts", 0)
      raise Error, "Gemini response had no text content part" if part.nil? || part["text"].nil?

      part["text"]
    end

    def cost_cents(model:, input_tokens:, output_tokens:)
      return nil if input_tokens.nil? || output_tokens.nil?

      rates = @pricing[model]
      return nil if rates.nil?

      input_cost = input_tokens * rates.fetch(:input_per_million)
      output_cost = output_tokens * rates.fetch(:output_per_million)
      ((input_cost + output_cost) / 1_000_000.0 * 100).round
    end
  end
end
