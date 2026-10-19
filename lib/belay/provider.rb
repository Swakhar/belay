# frozen_string_literal: true

module Belay
  # Interface every provider (FakeProvider, and later AnthropicProvider) implements. Pure
  # interface, no shared logic: #call must return a Belay::ProviderResponse or raise.
  #
  # schema: is for structured output (see README's Target API, llm(schema: InvoiceSchema))
  # - not validated or interpreted here. That belongs to the llm helper (Phase 1g), once
  # it exists to decide what "validate against a schema" even means for this gem.
  class Provider
    def call(model:, prompt:, schema: nil)
      raise NotImplementedError, "#{self.class} must implement #call(model:, prompt:, schema: nil)"
    end
  end
end
