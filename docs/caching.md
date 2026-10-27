# Caching

```ruby
step :classify, kind: "decision" do |ctx|
  ctx.llm(model: "claude-sonnet-5-5", prompt: Prompts.urgency(ctx.subject), schema: UrgencySchema, cacheable: true)
end
```

`cacheable: true` serves an exact repeat of this exact call - same provider, `model:`, `prompt:`, and `schema:` - from `belay_cache_entries` instead of making a real call.

## When to use it

**Never inferred from `kind:` or anything else about the step** - `kind: "llm_call"` covers both a classification call and an extraction call indistinguishably, so this is a plain, explicit choice the step author makes, the same contract `idempotent: true` already uses elsewhere: only set it on a call whose entire prompt text fully and uniquely determines the correct answer.

A short, self-contained classification prompt usually qualifies. An extraction prompt that references a large document - especially over a vision/file attachment, whose bytes aren't part of what gets hashed - usually doesn't: two different documents could share a cache key and get back the wrong answer.

## How it works

The cache key is `SHA256([provider class, model, prompt, schema].inspect)` - exact, literal match only; symbol- and string-keyed `prompt`/`schema` hash differently, on purpose.

A response is only ever cached after `schema:` validation succeeds, so a bad answer can never get stuck replaying itself. A hit records `cache_hit: true` on the step row with zeroed tokens/cost/latency (the true cost of a hit really is zero), visible on both the run detail page and the [Stats chart](dashboard.md).

```ruby
Belay.configure { |config| config.cache_ttl = 7 * 24 * 60 * 60 } # default; nil never expires
```

`cache_ttl` is one global setting, read fresh on every cache write - not a per-call override.
