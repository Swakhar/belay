# Providers

```ruby
provider = Belay::AnthropicProvider.new(
  api_key: Rails.application.credentials.anthropic_api_key, # or ENV["ANTHROPIC_API_KEY"] by default
  pricing: { "claude-sonnet-5-5" => { input_per_million: 3.0, output_per_million: 15.0 } } # optional; cost_cents is nil without it
)
Belay.configure { |config| config.provider = provider }
```

Belay isn't Anthropic-only. `Belay::Provider` is a pure interface - `#call(model:, prompt:, schema: nil)` returning a `Belay::ProviderResponse` or raising. `Belay::AnthropicProvider` (and `Belay::FakeProvider`, used throughout this gem's own test suite) are just two implementations of it; nothing in `Context#llm`, caching, replay's `model_override`, or cost tracking knows or cares which provider is configured.

## Writing your own

```ruby
class OpenAIProvider < Belay::Provider
  def call(model:, prompt:, schema: nil)
    # translate to the provider's own request shape, call its API, parse the response
    Belay::ProviderResponse.new(content: ..., model: model, input_tokens: ..., output_tokens: ...,
                                cost_cents: ..., latency_ms: ...)
  end
end
```

`content` and `model` are required; the token/cost/latency fields default to `nil` (not every provider call has them - a tool_call step has no token usage at all, and only the provider itself knows its own pricing well enough to fill in `cost_cents`).

## What `AnthropicProvider` adds

`InvoiceSchema` must set `additionalProperties: false` on every object in the schema, if it's ever run against `AnthropicProvider` - Anthropic's own requirement for structured outputs. `pricing:` is deliberately not pre-filled with Anthropic's current rates - they change, and a stale hardcoded number is worse than an honest `nil`. `response.cost_cents` is `nil` for any model you haven't priced.

`ctx.llm` itself also validates `response.content` against `schema:` (via [json_schemer](https://github.com/davishmcclurg/json_schemer)), provider-agnostically - `AnthropicProvider`'s own `schema:` already asks Anthropic's API to constrain its output, but `FakeProvider` enforces nothing at all, so this is the one place that's true no matter which provider is configured.
