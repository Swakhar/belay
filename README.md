# Belay

Durable execution for AI agents in Rails.

Sidekiq gives you durable background jobs. Belay gives you durable *AI* jobs — every model call and tool call is a database row, so a run can crash at step 47 and resume at step 47.

It sits under whatever prompting style you use and records everything. It is not a prompt library, not a chain-builder DSL, and not a wrapper that hides your LLM SDK.

**Status:** pre-release. Phase 1 (core runtime) complete as of `v0.1.0.pre1`; Phase 2 (gates & dashboard), Phase 2.5 (dashboard UI) and Phase 3 (replay) complete as of this commit. `Belay::Workflow` (`input`/`step`/`.start`), checkpointing, resume, retries, the idempotent:/needs_review policy, lease-based concurrency (`ResumeRunJob`/`JanitorJob`), `Belay::AnthropicProvider`, and `ctx.llm` are implemented and proven with real process kills and real concurrent workers, not just designed (see DESIGN_DECISIONS.md #13). `gate(name, when:)` is checkpointed correctly either way: `when:` false skips it and the run continues past it; `when:` true pauses the run (releasing its lease) and leaves it `awaiting_approval`, resolved by `run.approve!(by:, edited_payload: nil)`/`run.reject!(by:)`. A `needs_review` step (orphaned by a crash, not declared `idempotent: true`) is resolved the same way by `run.resolve_needs_review!(by:, outcome:, output: nil)`. `run.replay(model:)` re-runs a completed run's `llm_call` steps against a different model, serving everything else (plain Ruby steps, tool calls, gate decisions) from what actually happened the first time - `run.replay_diff` compares the two, step by step. `Belay::Engine` is mountable (`mount Belay::Engine => "/belay"`), gated behind a configurable `authenticate_with` hook with no default that lets anyone through, and its dashboard (a real runs index with status/workflow filters, a run detail page with the full step timeline - every retry attempt, each `llm_call` step's prompt/response/model/tokens/cost - forms for all three resolve actions above, and a side-by-side replay diff view) is implemented and proven with real HTTP requests through Rails' own router and middleware, not just designed. See Mounting the dashboard, below. A run executes synchronously in the calling process until it either finishes or hits a gate/needs_review pause; `ResumeRunJob` is only on the hot path once one of those resumes it.

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

## Mounting the dashboard

```ruby
# config/routes.rb
mount Belay::Engine => "/belay"

# config/initializers/belay.rb
Belay.configure do |config|
  config.authenticate_with = ->(request) { request.env["warden"]&.authenticate(:scope => :admin) }
end
```

`Belay::Engine` is a real, isolated `Rails::Engine` (`isolate_namespace Belay`, so its routes/controllers never collide with a host app's own) - mounting it is implemented and proven with a real HTTP request through Rails' own router and middleware stack, not just designed (`spec/belay/engine_spec.rb`). `authenticate_with` gates every request: a `->(request) { ... }` proc returning truthy allows it, anything else gets a plain `401`. It has no default that allows anyone through - the dashboard shows prompts, responses, costs and approve/reject actions, so mounting the engine without configuring this raises a clear `Belay::Error` on the very first request, rather than quietly serving it to the whole internet.

Its root page is a real runs index (`Belay::RunsController#index`): every run, most recently created first, with `?status=` and `?workflow=` filters (both shown as `<select>` dropdowns listing every value actually seen) - `status=` ignores anything that isn't one of `Run`'s declared statuses rather than raising on a mistyped or hand-edited URL, since it's untrusted query input the same as any GET param. Each run links to a real detail page (`Belay::RunsController#show`): every step in position order, including every retry attempt (a timeline is a record of what happened, not just the final outcome), and for an `llm_call` step specifically, its prompt, response, model, token counts and cost. `ctx.llm`'s `prompt:` is now captured onto the step's own `input` column (`Context#llm_metadata` includes `input: prompt`, merged in exactly like `provider`/`model`/the token counts already were) - the first thing that column, reserved since Phase 1b, actually gets used for.

When a run is paused on a gate, its show page displays a form to `POST approve_run_path`/`reject_run_path` directly - approving records who approved it (a required, plain `by:` form field; this gem has no identity concept of its own to derive one from `authenticate_with`, which only ever answers "is this request allowed," not "who is asking") and an optional JSON textarea for `edited_payload`, rejecting records who rejected it. Both redirect back to the run with a flash message, including on failure (no pending gate, invalid JSON) rather than raising into a raw 500.

A `needs_review` step (orphaned by a crash, not declared `idempotent: true`) gets the same treatment: the show page's `POST resolve_run_path` takes `by:`, an `outcome:` of `"succeeded"` or `"failed"` (`Run#resolve_needs_review!`'s own `RESOLUTIONS`), and - only for `"succeeded"` - an optional JSON `output:`, since the step's own block never actually returned one to recover. `"succeeded"` resumes the run past it the same way `approve!` does; `"failed"` fails the run directly, the same way `reject!` does, rather than resuming into the executor's retry logic with this step's attempt count already at whatever it was when it crashed. No `Belay::Approval` row here - that model is scoped to gates specifically (including its unique-per-gate-step index); `belay_steps` gained its own `resolved_by`/`resolved_at` columns instead.

A run that's a replay shadow (`run.replay_of` present) links back to the run it was replayed from, and any run with replays of its own lists them, each linking to `Belay::RunsController#diff` (`GET diff_run_path`): a side-by-side table of `run.replay_diff`, one row per step, flagged changed/unchanged/not-reached (not-reached when the shadow's own replay never actually got that far - see `Run#replay_diff`'s own comment for why that's a known, accepted limitation rather than a bug). A replay shadow's needs_review resolve section (below) is deliberately never shown - it isn't a real decision point, just a mirror of where the original run stopped.

The dashboard is styled with Tailwind, compiled and vendored - `app/assets/belay/application.css` is a committed build, inlined into the layout via `Belay::Engine.stylesheet`, not served through whichever asset pipeline (Sprockets, Propshaft, none at all) the host app happens to have, the same way this gem has never assumed Zeitwerk or any other host-app convention elsewhere. There's no runtime build step and no npm dependency for anyone who installs this gem. Contributing to the gem itself and changing a view's classes? `npm install && npm run build:css` regenerates it from `tailwind/application.css` - see `package.json`.

Every page shares the same small design system rather than each view inventing its own look: `Belay::ApplicationHelper#status_badge` is the one place deciding what a status looks like, grouped by what it *means* rather than by its literal value - `succeeded`/`completed` (emerald), `paused`/`awaiting_approval`/`needs_review` (amber - stopped, waiting on a human), `failed`/`cancelled` (rose), `running`/`started` (sky), anything else falls back to a neutral slate rather than raising on an unrecognized status. `tailwind/application.css`'s `@layer components` defines a fixed, small set of button/field classes (`.btn-primary`/`-secondary`/`-danger`, `.input-field`/`.select-field`/`.textarea-field`, `.field-label`) that every form on every page reuses, instead of each template writing its own ad hoc utility-class soup. The run detail page's step timeline (`app/views/belay/runs/_step.html.erb`) is a real vertical timeline, not a table - each step is its own card, rendered once via `render partial: ..., collection: @steps`, with the run's header, pending-gate and needs_review sections each their own short partial too, so no single view file is long.

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

  gate :approval, when: ->(ctx) { ctx.extract[:total_cents] > 100_00 } # true pauses for a human

  step :book, idempotent: true do |ctx|
    Bookkeeping.record!(ctx.extract, key: ctx.step_idempotency_key)
  end
end

run = InvoiceWorkflow.start(invoice_id: 42, idempotency_key: "inv-42")
run.status        # => "paused" if the gate's when: was true; "completed" if every gate skipped
run.pending_gate  # the awaiting_approval Belay::Step, or nil if nothing's paused on a gate
run.approve!(by: current_user.email) # resumes the run past the gate, via ResumeRunJob
run.approve!(by: current_user.email, edited_payload: { total_cents: 42_00 }) # becomes ctx.approval downstream
run.reject!(by: current_user.email)  # fails the run outright - nothing to resume into

run.pending_needs_review # the needs_review Belay::Step, or nil if nothing's flagged
run.resolve_needs_review!(by: current_user.email, outcome: "succeeded", output: { total_cents: 42_00 })
run.resolve_needs_review!(by: current_user.email, outcome: "failed") # fails the run outright, same as reject!
```

`input`, `step` (including `retries:` and `kind:`), `workflow_version`, `.start` with idempotency_key deduplication, and `ctx.step_idempotency_key` are implemented, against the real checkpoint/resume mechanics below — not a stub.

`gate(name, when:)` is implemented against the real checkpoint/resume mechanics too: `when:` is evaluated with the step's own context (prior outputs included), same as any step's block. False checkpoints the gate `skipped` (DESIGN_DECISIONS #7, "gates are steps" - a gate shares the same ordered list and resume/retry machinery `step` does, not a separate path) and the run continues past it; resuming a run that already has a skipped gate reuses that row without re-evaluating `when:`. True checkpoints the gate `awaiting_approval`, pauses the run, releases its lease, and stops - no further steps run, and `run.pending_gate` finds that step.

Resolving a pending gate is `run.approve!(by:, edited_payload: nil)`/`run.reject!(by:)`. `approve!` records a `Belay::Approval` (status `"approved"`, `decided_by: by`, `decided_at: Time.current`), settles the gate step `"succeeded"` (not `"skipped"` - that's reserved for `when:` false; this is `when:` true plus a human sign-off, a meaningfully different outcome), resumes the run, and enqueues `ResumeRunJob` to continue past it. `reject!` records an `Approval` with status `"rejected"`, settles the gate `"failed"` (there's no separate "rejected" step status), and fails the run directly rather than enqueueing anything - there's no step to resume into once a gate is rejected. Both raise a clear `Belay::Error` if the run has no pending gate. `by:` is written as-is to a plain string column (`decided_by`) - pass something meant to be read back later (an email, a username, an id), not a full user object.

`approve!`'s `edited_payload:` becomes the gate step's own output (gates settled via `when:` never have one - only their status changes), readable by any later step the same way it reads any other step's output: `ctx.<gate name>`. It's a deliberately narrower feature than "edit the data the gate's `when:` actually depended on" - the DSL has no declared link between a gate and which step(s) fed its condition, so there's no single other row this could unambiguously override instead. The edited value is also recorded on the `Approval` itself (same value, a separate column), so a dashboard can show what was edited without reaching through the gate's own output.

A step is never re-executed once its output is checkpointed. A step's block raising is caught, marked failed with the error recorded, and retried up to `retries:` times before propagating. A step orphaned by a crash (found `started`, no exception ever caught) is resumed automatically only if declared `idempotent: true`; otherwise it's flagged `needs_review`, the run is paused, and the step's own block never runs again until a human resolves it.

Resolving a `needs_review` step is `run.resolve_needs_review!(by:, outcome:, output: nil)`. `outcome: "succeeded"` settles the step with whatever `output:` is supplied (there's no real one to recover - the block never returned one), resumes the run and enqueues `ResumeRunJob`, the same shape as `approve!`. `outcome: "failed"` settles it failed and fails the run directly, the same shape as `reject!` - deliberately never resuming into the executor's own retry logic, which could either raise uncaught (a step with no `retries:` left) or silently re-execute the block (a step with `retries:` left that hadn't exhausted them yet - exactly the side effect a human just confirmed did NOT happen). No `Belay::Approval` row here - that model is scoped to gates specifically, including its unique-per-gate-step index; `belay_steps` has its own `resolved_by`/`resolved_at` columns instead, claimed with a conditional `UPDATE` rather than a unique-index collision, since there's no separate row to collide on for this kind of resolution.

See [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) for the delivery guarantee (at-least-once, exactly-once only for idempotent steps - decision #2, proven against the real gem with real process kills and real concurrent workers by decision #13) and the reasoning behind the rest of the design.

## Replay

```ruby
shadow = run.replay(model: "claude-opus-5-5")  # a fresh, separate Run
shadow.replay_of   # => the original run
run.replays        # => [shadow, ...] - every replay of this run
shadow.replay_diff # => [{ position:, name:, kind:, original_output:, replay_output:, replayed:, changed: }, ...]
```

`run.replay(model: nil)` creates a shadow run and runs it for real: every `llm_call` step is re-executed against `model:` (or whatever model the step's own block already specified, if `model:` is omitted - either way, a real provider call, not a cached one), while every other step - plain Ruby, tool calls, and gate decisions alike - is served from `run`'s own recorded output, never re-executed. DESIGN_DECISIONS #8: replay compares extractions; it does not book the invoice a second time. Refuses (raises a clear `Belay::Error`, doesn't warn-and-proceed) if the workflow's current `workflow_version` doesn't match what `run` actually executed against - a changed step list makes any diff computed afterward meaningless, not just suspect.

`replay_diff` compares the shadow against the run it replayed, position by position: `changed` is a plain `!=` on the two outputs (not a deep diff of exactly what moved inside a Hash), and `replayed` distinguishes "never got this far" from "got here and didn't change" - a replay that fails partway through (a bad override model, a provider outage) leaves every later position with `replayed: false`.

A model: override reaching the actual provider call, not just a workflow author's own hardcoded `model:` string, is the entire mechanism: `ctx.llm`'s `model:` argument becomes a default a replay's override replaces, invisibly to the step's own code.

## ctx.llm

`ctx.llm(model:, prompt:, schema: nil)` calls `Belay.config.provider` (configure one first, e.g. `Belay::AnthropicProvider.new` - see Configuration above) and returns `response.content` directly - that return value becomes the step's own checkpointed output, so `step :extract do |ctx| ctx.llm(...) end` needs nothing further.

It's `ctx.llm`, not a bare top-level `llm(...)` the way an earlier sketch of this API had it. A step's block runs via plain `.call`, not `instance_exec`, so a bare `llm(...)` would need to be a class-level method every `Workflow` subclass inherits, with no explicit per-step state - which is exactly the kind of implicit ambient context (`Thread.current`-style, or an `ActiveSupport::CurrentAttributes`-alike) `ctx` already exists to avoid. Routing it through `ctx`, which every step block already receives explicitly, needed no new state and no class-level DSL method.

Two things `ctx.llm` does that calling a provider directly does not:

- **Validates `response.content` against `schema:`** (via [json_schemer](https://github.com/davishmcclurg/json_schemer)), provider-agnostically. `AnthropicProvider`'s own `schema:` already asks Anthropic's API to constrain its output, but `FakeProvider` enforces nothing at all - this is the one place that's true no matter which provider is configured, so a spec's scripted response that doesn't actually match the `schema:` it claims to fails loudly, in the test, not silently until production. `schema:` may use symbol or string keys/values either way (both are normalized the same before validating); `response.content` is returned to the step exactly as the provider gave it, never mutated by this normalization.
- **Records `prompt:` itself (as `input`), `provider`/`model`/`input_tokens`/`output_tokens`/`cost_cents`/`latency_ms` onto the step's own `belay_steps` row** once the step finishes (success or failure - a provider call that happened before the block went on to raise is still a real, billed call, and isn't dropped). A step whose `kind:` wasn't declared explicitly is upgraded from the `"decision"` default to `"llm_call"` once it's known the block actually called `ctx.llm`; an explicit `kind:` is never overridden.

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
