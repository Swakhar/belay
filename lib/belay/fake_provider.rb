# frozen_string_literal: true

module Belay
  # A Provider for specs: no network, a fixed script of responses, and a record of
  # every call so a spec can assert what was actually sent. See section 9 of the
  # architecture notes ("FakeProvider with scripted responses - no network in tests").
  class FakeProvider < Provider
    class ScriptExhaustedError < Error; end

    # responses: each entry is either a ProviderResponse (full control over model/
    # tokens/cost/latency) or a plain String/anything else, auto-wrapped as
    # ProviderResponse.new(content: entry, model: model) using whatever model the
    # matching call actually asked for - the common "just give back this content" case
    # shouldn't need to predict which model name will be passed.
    def initialize(responses: [])
      super()
      @responses = responses.dup
      @calls = []
    end

    # Frozen dup, same reasoning as Workflow#steps/#inputs: a spec reaching in and
    # doing provider.calls.clear or provider.calls << {...} would otherwise corrupt
    # this provider's own record of what it actually received.
    def calls
      @calls.dup.freeze
    end

    def call(model:, prompt:, schema: nil)
      @calls << { model: model, prompt: prompt, schema: schema }.freeze

      if @responses.empty?
        raise ScriptExhaustedError,
              "#{self.class} received call ##{@calls.size} (model: #{model.inspect}) with no scripted " \
              "response left - pass more entries to responses:"
      end

      response = @responses.shift
      response.is_a?(ProviderResponse) ? response : ProviderResponse.new(content: response, model: model)
    end
  end
end
