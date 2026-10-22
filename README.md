# Belay

Durable execution for AI agents in Rails.

Sidekiq gives you durable background jobs. Belay gives you durable *AI* jobs — every model call and tool call is a database row, so a run can crash at step 47 and resume at step 47.

It sits under whatever prompting style you use and records everything. It is not a prompt library, not a chain-builder DSL, and not a wrapper that hides your LLM SDK.

**Status:** pre-release, Phase 1 (core runtime) complete as of `v0.1.0.pre1`, Phase 2 (gates & dashboard) in progress. `Belay::Workflow` (`input`/`step`/`.start`), checkpointing, resume, retries, the idempotent:/needs_review policy, lease-based concurrency (`ResumeRunJob`/`JanitorJob`), `Belay::AnthropicProvider`, and `ctx.llm` are implemented and proven with real process kills and real concurrent workers, not just designed (see DESIGN_DECISIONS.md #13) — the "boring," no-gate path of the Target API below actually runs. `gate` is checkpointed correctly when its `when:` evaluates false (skipped, and the run continues past it); when `when:` evaluates true, it raises a clear "not implemented yet" error instead of silently proceeding, since pausing the run for a human is the next commit's job, not this one's. Not yet implemented: `pending_gate`, `approve!`/`reject!`, the dashboard (rest of Phase 2) — a run executes synchronously in the calling process today; nothing enqueues `ResumeRunJob` yet, so leases exist but aren't on the hot path until something does.

## Installation

```ruby
# Gemfile
gem "belay"
```

```sh
bundle install
```

Requires Ruby 3.2+, Rails 7.1+, and Postgres. See [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) for why.

```sh
rails generate belay:install
rails db:migrate
```

This creates the `belay_runs` and `belay_steps` migrations, and is implemented, along with the models, DSL, and executor that use them — see Target API, below.

## Configuration

```ruby
# config/initializers/belay.rb
Belay.configure do |config|
  config.lease_duration = 300     # seconds a worker holds a run before the janitor reclaims it
  config.heartbeat_interval = 30  # seconds between heartbeats while a step is in flight
  config.provider = Belay::AnthropicProvider.new # the provider ctx.llm calls
end
```

`lease_duration`/`heartbeat_interval` default to the values above; the initializer is only needed to change them. `lease_duration` is read by `Run#acquire_lease!`/`#heartbeat_lease!` and `JanitorJob`; `heartbeat_interval` is how often a caller is expected to heartbeat (nothing currently heartbeats automatically mid-step - see `lib/belay/resume_run_job.rb`'s and `lib/belay/janitor_job.rb`'s comments for the gap this leaves for a step slower than `lease_duration`). `provider` defaults to `nil` - a workflow with no `ctx.llm`-calling steps never needs it, but calling `ctx.llm` without configuring one raises a clear error.

## Target API

```ruby
class InvoiceWorkflow < Belay::Workflow
  input :invoice_id

  step :extract do |ctx|
    ctx.llm( # llm() on its own, as the spec sketch originally had it, is not how this
             # ended up implemented - see the note below the example
      model: "claude-sonnet-5-5",
      prompt: Prompts.extract(ctx.invoice.raw_text),
      schema: InvoiceSchema
    )
  end

  step :verify do |ctx|
    # deterministic Ruby — no model involved
    Verifier.check_totals!(ctx.extract)
  end

  gate :approval, when: ->(ctx) { ctx.extract[:total_cents] > 100_00 } # skip works; true raises - pausing is next

  step :book, idempotent: true do |ctx|
    Bookkeeping.record!(ctx.extract, key: ctx.step_idempotency_key)
  end
end

run = InvoiceWorkflow.start(invoice_id: 42, idempotency_key: "inv-42")
run.status        # => "paused" once approve!/reject! exist; today, "completed" if every gate skipped
run.pending_gate  # not yet implemented - Phase 2
run.approve!(by: current_user) # not yet implemented - Phase 2
```

`input`, `step` (including `retries:` and `kind:`), `workflow_version`, `.start` with idempotency_key deduplication, and `ctx.step_idempotency_key` are implemented, against the real checkpoint/resume mechanics below — not a stub.

`gate(name, when:)` is implemented against the real checkpoint/resume mechanics too, as far as it goes: `when:` is evaluated with the step's own context (prior outputs included), same as any step's block. False checkpoints the gate `skipped` (DESIGN_DECISIONS #7, "gates are steps" - a gate shares the same ordered list and resume/retry machinery `step` does, not a separate path) and the run continues past it; resuming a run that already has a skipped gate reuses that row without re-evaluating `when:`. True raises a clear "not implemented yet" error rather than silently proceeding - pausing the run for a human to approve is the next commit, not this one.

A step is never re-executed once its output is checkpointed. A step's block raising is caught, marked failed with the error recorded, and retried up to `retries:` times before propagating. A step orphaned by a crash (found `started`, no exception ever caught) is resumed automatically only if declared `idempotent: true`; otherwise it's flagged `needs_review`, the run is paused, and the step's own block never runs again until a human resolves it (no resolve action exists yet - that's part of the Phase 2 dashboard). See [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) for the delivery guarantee (at-least-once, exactly-once only for idempotent steps - decision #2, proven against the real gem with real process kills and real concurrent workers by decision #13) and the reasoning behind the rest of the design.

## ctx.llm

`ctx.llm(model:, prompt:, schema: nil)` calls `Belay.config.provider` (configure one first, e.g. `Belay::AnthropicProvider.new` - see Configuration above) and returns `response.content` directly - that return value becomes the step's own checkpointed output, so `step :extract do |ctx| ctx.llm(...) end` needs nothing further.

It's `ctx.llm`, not a bare top-level `llm(...)` the way an earlier sketch of this API had it. A step's block runs via plain `.call`, not `instance_exec`, so a bare `llm(...)` would need to be a class-level method every `Workflow` subclass inherits, with no explicit per-step state - which is exactly the kind of implicit ambient context (`Thread.current`-style, or an `ActiveSupport::CurrentAttributes`-alike) `ctx` already exists to avoid. Routing it through `ctx`, which every step block already receives explicitly, needed no new state and no class-level DSL method.

Two things `ctx.llm` does that calling a provider directly does not:

- **Validates `response.content` against `schema:`** (via [json_schemer](https://github.com/davishmcclurg/json_schemer)), provider-agnostically. `AnthropicProvider`'s own `schema:` already asks Anthropic's API to constrain its output, but `FakeProvider` enforces nothing at all - this is the one place that's true no matter which provider is configured, so a spec's scripted response that doesn't actually match the `schema:` it claims to fails loudly, in the test, not silently until production. `schema:` may use symbol or string keys/values either way (both are normalized the same before validating); `response.content` is returned to the step exactly as the provider gave it, never mutated by this normalization.
- **Records `provider`/`model`/`input_tokens`/`output_tokens`/`cost_cents`/`latency_ms` onto the step's own `belay_steps` row** once the step finishes (success or failure - a provider call that happened before the block went on to raise is still a real, billed call, and isn't dropped). A step whose `kind:` wasn't declared explicitly is upgraded from the `"decision"` default to `"llm_call"` once it's known the block actually called `ctx.llm`; an explicit `kind:` is never overridden.

```ruby
provider = Belay::AnthropicProvider.new(
  api_key: Rails.application.credentials.anthropic_api_key, # or ENV["ANTHROPIC_API_KEY"] by default
  pricing: { "claude-sonnet-5-5" => { input_per_million: 3.0, output_per_million: 15.0 } } # optional; cost_cents is nil without it
)
Belay.configure { |config| config.provider = provider }
```

`InvoiceSchema` must set `additionalProperties: false` on every object in the schema, if it's ever run against `AnthropicProvider` - Anthropic's own requirement for structured outputs. `pricing:` is deliberately not pre-filled with Anthropic's current rates - they change, and a stale hardcoded number is worse than an honest `nil`. `response.cost_cents` is `nil` for any model you haven't priced.

## Roadmap

See [ROADMAP.md](ROADMAP.md).

## License

MIT. See [LICENSE](LICENSE).
