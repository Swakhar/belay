# Belay

Durable execution for AI agents in Rails.

Sidekiq gives you durable background jobs. Belay gives you durable *AI* jobs — every model call and tool call is a database row, so a run can crash at step 47 and resume at step 47.

It sits under whatever prompting style you use and records everything. It is not a prompt library, not a chain-builder DSL, and not a wrapper that hides your LLM SDK.

**Status:** pre-release. `Belay::Workflow` (`input`/`step`/`.start`), checkpointing, resume, retries, and the idempotent:/needs_review policy are implemented — the "boring," no-gate path of the Target API below actually runs. Not yet implemented: `gate`, `pending_gate`, `approve!`/`reject!` (Phase 2), the `llm` helper and a real provider (Phase 1g), and leases/background jobs (Phase 1f) — a run executes synchronously in the calling process today.

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
end
```

Both settings default to the values above; the initializer is only needed to change them. Nothing reads them yet — that's the leases work in Phase 1f.

## Target API

```ruby
class InvoiceWorkflow < Belay::Workflow
  input :invoice_id

  step :extract do |ctx|
    llm( # not yet implemented - the llm helper and a real provider are Phase 1g
      model: "claude-sonnet-4-6",
      prompt: Prompts.extract(ctx.invoice.raw_text),
      schema: InvoiceSchema
    )
  end

  step :verify do |ctx|
    # deterministic Ruby — no model involved
    Verifier.check_totals!(ctx.extract)
  end

  gate :approval, when: ->(ctx) { ctx.extract[:total_cents] > 100_00 } # not yet implemented - Phase 2

  step :book, idempotent: true do |ctx|
    Bookkeeping.record!(ctx.extract, key: ctx.step_idempotency_key)
  end
end

run = InvoiceWorkflow.start(invoice_id: 42, idempotency_key: "inv-42")
run.status        # => "paused" once gates exist; today, "completed" or "paused" (needs_review stopped it)
run.pending_gate  # not yet implemented - Phase 2
run.approve!(by: current_user) # not yet implemented - Phase 2
```

`input`, `step` (including `retries:` and `kind:`), `workflow_version`, `.start` with idempotency_key deduplication, and `ctx.step_idempotency_key` are implemented, against the real checkpoint/resume mechanics below — not a stub.

A step is never re-executed once its output is checkpointed. A step's block raising is caught, marked failed with the error recorded, and retried up to `retries:` times before propagating. A step orphaned by a crash (found `started`, no exception ever caught) is resumed automatically only if declared `idempotent: true`; otherwise it's flagged `needs_review`, the run is paused, and the step's own block never runs again until a human resolves it (no resolve action exists yet - that's part of the Phase 2 dashboard). See [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) for the delivery guarantee (at-least-once, exactly-once only for idempotent steps) and the reasoning behind the rest of the design.

## Roadmap

See [ROADMAP.md](ROADMAP.md).

## License

MIT. See [LICENSE](LICENSE).
