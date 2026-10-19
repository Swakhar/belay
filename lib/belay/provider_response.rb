# frozen_string_literal: true

module Belay
  # What every Belay::Provider#call returns. content and model are required - a response
  # without either is a bug in the provider, not a legitimate "empty" result. The token/
  # cost/latency fields default to nil: not every provider call has them (a tool_call
  # step has no token usage at all), and only the provider itself knows its own pricing
  # well enough to fill in cost_cents.
  ProviderResponse = Struct.new(:content, :model, :input_tokens, :output_tokens, :cost_cents, :latency_ms,
                                keyword_init: true) do
    def initialize(**attrs)
      super
      raise ArgumentError, "ProviderResponse requires content" if content.nil?
      raise ArgumentError, "ProviderResponse requires model" if model.nil?

      freeze
    end
  end
end
