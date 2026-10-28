# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Belay
  # Calls OpenAI's API directly over Net::HTTP (stdlib) - same reasoning as
  # AnthropicProvider: no SDK gem, so no second gem's own version matrix for
  # this gem to track for a provider this central. POST a JSON body, read a
  # JSON body back is small enough that stdlib Net::HTTP + JSON covers it.
  #
  # api: picks which of OpenAI's two current text-generation APIs to call -
  # :responses (default, OpenAI's own forward-looking API, POST /v1/responses)
  # or :chat_completions (the older, still fully supported POST
  # /v1/chat/completions). Both are real, current APIs, not a deprecated/
  # replacement pair, and their request/response shapes differ enough
  # (structured-output config lives at text.format vs response_format; usage
  # keys are input_tokens/output_tokens vs prompt_tokens/completion_tokens;
  # truncation and refusal surface completely differently - see
  # extract_responses_content/extract_chat_completions_content below) that
  # this class branches internally on @api rather than guessing one and
  # forcing callers who need the other to go write their own provider. The
  # public interface (#call) and everything around it (errors, cost, latency)
  # is identical either way.
  #
  # Endpoint and field names verified against OpenAI's own public OpenAPI spec
  # (github.com/openai/openai-openapi) as of 2026-10-28.
  #
  # schema: on :responses sets text.format: {type: "json_schema", name:,
  # schema:, strict: true}; on :chat_completions it's response_format:
  # {type: "json_schema", json_schema: {name:, schema:, strict: true}}.
  # Unlike Anthropic, OpenAI requires a name: on the schema either way - a
  # fixed, gem-chosen value (SCHEMA_NAME) is used throughout, since nothing
  # about the schema format itself needs that name to be caller-visible.
  # strict: true is always passed (not left to OpenAI's own default: false) -
  # a non-strict schema is advisory only, and this gem's own
  # StructuredOutputError handling below assumes a schema that was actually
  # enforced.
  #
  # refusal/truncation are each mapped to the same StructuredOutputError
  # reason: values AnthropicProvider uses ("refusal"/"max_tokens"), so a
  # caller can branch on reason: the same way regardless of which provider is
  # configured:
  #   :responses        - a "refusal" content item on the output message ->
  #                        "refusal"; status: "incomplete" with
  #                        incomplete_details.reason == "max_output_tokens" ->
  #                        "max_tokens"
  #   :chat_completions  - message.refusal present -> "refusal";
  #                        finish_reason == "length" -> "max_tokens"
  # Both checks, like AnthropicProvider's own, only run when schema: was
  # given - a refusal or truncation on a plain-text call isn't this gem's
  # problem to second-guess; it surfaces as whatever text (or lack of it)
  # the author's own code then has to deal with, same as any other provider.
  # Genuinely two providers' worth of request/response handling behind one #call
  # interface (see api: above), not one class that grew unchecked - same
  # ClassLength exemption reasoning as Executor::StepRunner (executor.rb).
  class OpenAIProvider < Provider # rubocop:disable Metrics/ClassLength
    API_URLS = {
      responses: URI("https://api.openai.com/v1/responses"),
      chat_completions: URI("https://api.openai.com/v1/chat/completions")
    }.freeze

    SCHEMA_NAME = "belay_response"

    # Raised on any non-2xx response. OpenAI's own error body (JSON, usually
    # {"error": {"type":, "message":}}) is preserved verbatim in the message,
    # same reasoning as AnthropicProvider::RequestError.
    class RequestError < Error
      attr_reader :status

      def initialize(status:, body:)
        @status = status
        super("OpenAI API request failed with status #{status}: #{body}")
      end
    end

    # Raised when schema: was given but the response can't be trusted to
    # contain valid, complete schema-matching JSON. reason: is "refusal" or
    # "max_tokens" - see the class comment above for exactly what maps to
    # each, per api:.
    class StructuredOutputError < Error
      attr_reader :reason, :response

      def initialize(reason:, response:)
        @reason = reason
        @response = response
        super("OpenAI did not return schema-matching output (reason: #{reason.inspect}): #{response.inspect}")
      end
    end

    # pricing: {"gpt-..." => { input_per_million: <USD Float>, output_per_million: <USD Float> }, ...}
    # Deliberately not pre-filled with OpenAI's current rates - same reasoning
    # as AnthropicProvider's own pricing: comment.
    def initialize(api_key: ENV.fetch("OPENAI_API_KEY", nil), api: :responses, max_tokens: 4096, pricing: {})
      super()
      raise ArgumentError, "#{self.class} requires api_key: (or OPENAI_API_KEY)" if api_key.nil?
      raise ArgumentError, "api: must be one of #{API_URLS.keys.inspect}, got #{api.inspect}" unless API_URLS.key?(api)

      @api_key = api_key
      @api = api
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
      return responses_request_body(model, prompt, schema) if @api == :responses

      chat_completions_request_body(model, prompt, schema)
    end

    def responses_request_body(model, prompt, schema)
      body = { model: model, input: prompt, max_output_tokens: @max_tokens }
      return body if schema.nil?

      body.merge(text: { format: { type: "json_schema", name: SCHEMA_NAME, schema: schema, strict: true } })
    end

    def chat_completions_request_body(model, prompt, schema)
      body = { model: model, max_completion_tokens: @max_tokens, messages: [{ role: "user", content: prompt }] }
      return body if schema.nil?

      body.merge(response_format: { type: "json_schema",
                                    json_schema: { name: SCHEMA_NAME, schema: schema, strict: true } })
    end

    def perform_request(body)
      response = Net::HTTP.post(API_URLS.fetch(@api), JSON.generate(body), request_headers)
      [response.code.to_i, response.body]
    end

    def request_headers
      { "Authorization" => "Bearer #{@api_key}", "content-type" => "application/json" }
    end

    def build_response(response, model:, schema:, latency_ms:)
      usage = response["usage"] || {}
      input_tokens, output_tokens = usage_tokens(usage)

      ProviderResponse.new(
        content: extract_content(response, schema: schema),
        model: response["model"] || model,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost_cents: cost_cents(model: model, input_tokens: input_tokens, output_tokens: output_tokens),
        latency_ms: latency_ms
      )
    end

    def usage_tokens(usage)
      keys = @api == :responses ? %w[input_tokens output_tokens] : %w[prompt_tokens completion_tokens]
      usage.values_at(*keys)
    end

    def extract_content(response, schema:)
      return extract_responses_content(response, schema: schema) if @api == :responses

      extract_chat_completions_content(response, schema: schema)
    end

    def extract_responses_content(response, schema:)
      message = find_output_message(response)
      return extract_responses_structured_output(response, message) if schema

      text = output_text(message)
      raise Error, "OpenAI response had no output_text content" if text.nil?

      text
    end

    def extract_responses_structured_output(response, message)
      raise StructuredOutputError.new(reason: "refusal", response: response) if refusal?(message)
      raise StructuredOutputError.new(reason: "max_tokens", response: response) if responses_truncated?(response)

      text = output_text(message)
      raise Error, "OpenAI response had no output_text content" if text.nil?

      JSON.parse(text)
    end

    def find_output_message(response)
      message = (response["output"] || []).find { |item| item["type"] == "message" }
      raise Error, "OpenAI response had no output message" if message.nil?

      message
    end

    def output_text(message)
      text_block = (message["content"] || []).find { |c| c["type"] == "output_text" }
      text_block && text_block["text"]
    end

    def refusal?(message)
      (message["content"] || []).any? { |c| c["type"] == "refusal" }
    end

    def responses_truncated?(response)
      response["status"] == "incomplete" && response.dig("incomplete_details", "reason") == "max_output_tokens"
    end

    def extract_chat_completions_content(response, schema:)
      return extract_chat_completions_structured_output(response) if schema

      content = response.dig("choices", 0, "message", "content")
      raise Error, "OpenAI response had no message content" if content.nil?

      content
    end

    def extract_chat_completions_structured_output(response)
      message = response.dig("choices", 0, "message") || {}
      raise StructuredOutputError.new(reason: "refusal", response: response) if message["refusal"]

      finish_reason = response.dig("choices", 0, "finish_reason")
      raise StructuredOutputError.new(reason: "max_tokens", response: response) if finish_reason == "length"

      content = message["content"]
      raise Error, "OpenAI response had no message content" if content.nil?

      JSON.parse(content)
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
