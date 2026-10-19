# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Belay
  # Calls Anthropic's Messages API directly over Net::HTTP (stdlib) rather than via
  # the official anthropic gem - see belay-planning/DECISIONS.md for the reasoning:
  # this gem already has one cross-version dependency incident (the json/
  # activesupport quirks_mode break on Rails 7.1, see gemfiles/rails_7_1.gemfile),
  # and a provider this central shouldn't add a second gem's own version matrix to
  # track. The wire format needed here - POST a JSON body, read a JSON body back -
  # is small enough that stdlib Net::HTTP plus JSON covers it without one.
  #
  # Endpoint and headers verified against Anthropic's Messages API docs as of
  # 2026-10-19 (anthropic-version: 2023-06-01 is still the current, required
  # version string).
  #
  # schema: uses Anthropic's structured outputs (top-level output_config.format,
  # type: "json_schema"), not forced tool_choice. An earlier draft of this file used
  # tool_choice: {type: "tool", name: ...}, which 400s outright on Claude Opus 5.5,
  # Sonnet 5.5, Fable 5.1 and Mythos 5.1 - i.e. it would have broken on exactly the
  # model this file's own README example calls. output_config.format works across
  # the current model lineup, so that's what's implemented. Any object in schema:
  # needs additionalProperties: false, per Anthropic's own requirement for this
  # field - not validated here; an object schema missing it surfaces as a 400
  # (RequestError), same as any other malformed request.
  #
  # stop_reason is checked before parsing: "refusal" means Claude declined to
  # produce schema-matching output at all, "max_tokens" means what came back may be
  # truncated mid-JSON. Both raise StructuredOutputError with that reason rather
  # than attempt JSON.parse on text that may not actually be valid JSON.
  #
  # Deliberately does NOT ship a baked-in per-model price table. Anthropic's prices
  # change, this gem has no way to keep a hardcoded table current, and a silently
  # stale number is worse than an honest nil - the same reasoning ProviderResponse's
  # own comment gives for why cost_cents defaults to nil at all. Pass pricing: with
  # rates for whichever models you actually use; cost_cents is nil for any model not
  # in it, same as it would be if usage data were missing entirely.
  class AnthropicProvider < Provider
    API_URL = URI("https://api.anthropic.com/v1/messages")
    API_VERSION = "2023-06-01"

    # Raised on any non-2xx response. Anthropic's own error body (JSON, usually
    # {"error": {"type":, "message":}}) is preserved verbatim in the message rather
    # than parsed and re-interpreted, so whatever Anthropic actually said is visible
    # in the step's recorded error, not lossily summarized.
    class RequestError < Error
      attr_reader :status

      def initialize(status:, body:)
        @status = status
        super("Anthropic API request failed with status #{status}: #{body}")
      end
    end

    # Raised when schema: was given but Claude's response can't be trusted to
    # contain valid, complete schema-matching JSON. reason: is Anthropic's own
    # stop_reason ("refusal" or "max_tokens"), exposed so a caller can tell "ask a
    # human" (refusal) apart from "retry with a higher max_tokens" (max_tokens),
    # rather than both surfacing as the same undifferentiated Belay::Error.
    class StructuredOutputError < Error
      attr_reader :reason, :response

      def initialize(reason:, response:)
        @reason = reason
        @response = response
        super("Anthropic did not return schema-matching output (stop_reason: #{reason.inspect}): #{response.inspect}")
      end
    end

    # pricing: {"claude-..." => { input_per_million: <USD Float>, output_per_million: <USD Float> }, ...}
    #
    # max_tokens: counts thinking tokens too on models with thinking enabled by
    # default (e.g. Claude Opus 5) - a schema: call can hit max_tokens, and raise
    # StructuredOutputError, more easily than the number alone suggests. Raise this
    # if that happens in practice; there's no way to size it correctly up front
    # without knowing the model and its thinking behavior.
    def initialize(api_key: ENV.fetch("ANTHROPIC_API_KEY", nil), max_tokens: 4096, pricing: {})
      super()
      raise ArgumentError, "#{self.class} requires api_key: (or ANTHROPIC_API_KEY)" if api_key.nil?

      @api_key = api_key
      @max_tokens = max_tokens
      @pricing = pricing
    end

    def call(model:, prompt:, schema: nil)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, body = perform_request(request_body(model: model, prompt: prompt, schema: schema))
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      raise RequestError.new(status: status, body: body) unless status.between?(200, 299)

      build_response(JSON.parse(body), model: model, schema: schema, latency_ms: latency_ms)
    end

    private

    def request_body(model:, prompt:, schema:)
      body = { model: model, max_tokens: @max_tokens, messages: [{ role: "user", content: prompt }] }
      return body if schema.nil?

      body.merge(output_config: { format: { type: "json_schema", schema: schema } })
    end

    def perform_request(body)
      response = Net::HTTP.post(API_URL, JSON.generate(body), request_headers)
      [response.code.to_i, response.body]
    end

    def request_headers
      {
        "x-api-key" => @api_key,
        "anthropic-version" => API_VERSION,
        "content-type" => "application/json"
      }
    end

    def build_response(response, model:, schema:, latency_ms:)
      usage = response["usage"] || {}
      input_tokens, output_tokens = usage.values_at("input_tokens", "output_tokens")

      ProviderResponse.new(
        content: extract_content(response, schema: schema),
        model: response["model"] || model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost_cents: cost_cents(model: model, input_tokens: input_tokens, output_tokens: output_tokens),
        latency_ms: latency_ms
      )
    end

    def extract_content(response, schema:)
      schema ? extract_structured_output(response) : extract_text(response["content"] || [])
    end

    def extract_structured_output(response)
      stop_reason = response["stop_reason"]
      if %w[refusal max_tokens].include?(stop_reason)
        raise StructuredOutputError.new(reason: stop_reason, response: response)
      end

      JSON.parse(extract_text(response["content"] || []))
    end

    def extract_text(blocks)
      block = blocks.find { |b| b["type"] == "text" }
      raise Error, "Anthropic response had no text content block" if block.nil?

      block["text"]
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
