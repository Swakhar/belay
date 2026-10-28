---
layout: default
title: Providers
nav_order: 6
---

# Providers

```ruby
provider = Belay::AnthropicProvider.new(
  api_key: Rails.application.credentials.anthropic_api_key, # or ENV["ANTHROPIC_API_KEY"] by default
  pricing: { "claude-sonnet-5-5" => { input_per_million: 3.0, output_per_million: 15.0 } } # optional; cost_cents is nil without it
)
Belay.configure { |config| config.provider = provider }
```

Belay isn't Anthropic-only. `Belay::Provider` is a pure interface - `#call(model:, prompt:, schema: nil)` returning a `Belay::ProviderResponse` or raising. `Belay::AnthropicProvider`, `Belay::OpenAIProvider`, `Belay::GeminiProvider` (and `Belay::FakeProvider`, used throughout this gem's own test suite) are just implementations of it; nothing in `Context#llm`, caching, replay's `model_override`, or cost tracking knows or cares which provider is configured.

## Writing your own

```ruby
class MyProvider < Belay::Provider
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

## `OpenAIProvider`

```ruby
provider = Belay::OpenAIProvider.new(
  api_key: Rails.application.credentials.openai_api_key, # or ENV["OPENAI_API_KEY"] by default
  api: :responses, # or :chat_completions - both are real, current OpenAI APIs; see below
  pricing: { "gpt-5.1" => { input_per_million: 1.25, output_per_million: 10.0 } }
)
Belay.configure { |config| config.provider = provider }
```

`api:` picks which of OpenAI's two current text-generation APIs to call. `:responses` (the default) is OpenAI's own forward-looking API; `:chat_completions` is the older API most existing OpenAI integrations were built against. Both are fully supported, current APIs - pick whichever your account/models are already set up for. `schema:` works the same way either way (OpenAI's own Structured Outputs feature, with `strict: true` always set); so does `cost_cents:` via `pricing:`, same reasoning as `AnthropicProvider`'s own.

## `GeminiProvider`

```ruby
provider = Belay::GeminiProvider.new(
  api_key: Rails.application.credentials.gemini_api_key, # or ENV["GEMINI_API_KEY"] by default
  pricing: { "gemini-3-pro" => { input_per_million: 2.0, output_per_million: 12.0 } }
)
Belay.configure { |config| config.provider = provider }
```

One real gotcha if you use `schema:` with Gemini: its schema dialect uses its own **uppercase** type names (`"OBJECT"`, `"STRING"`, `"INTEGER"`, ...), not standard JSON Schema's lowercase ones, and doesn't support every JSON Schema keyword (no `additionalProperties`, unlike Anthropic). A schema written for `AnthropicProvider` or `OpenAIProvider` will not work here unchanged.

## A shared `StructuredOutputError`-style contract

Each provider that supports `schema:` (`AnthropicProvider`, `OpenAIProvider`, `GeminiProvider`) raises its own `StructuredOutputError` with a `reason:` of either `"refusal"` (the model declined to produce schema-matching output at all) or `"max_tokens"` (the response may be truncated mid-JSON) - never attempting `JSON.parse` on text that may not actually be valid JSON. The exact signal differs per provider's own API (Anthropic's `stop_reason`, OpenAI's refusal content item/`incomplete_details`, Gemini's `finishReason`), but `reason:` means the same thing regardless of which provider raised it, so code written against one provider's `rescue ... => e; e.reason` branches the same way against another's.

`ctx.llm` itself also validates `response.content` against `schema:` (via [json_schemer](https://github.com/davishmcclurg/json_schemer)), provider-agnostically - each provider's own `schema:` already asks its API to constrain output, but `FakeProvider` enforces nothing at all, so this is the one place that's true no matter which provider is configured.
