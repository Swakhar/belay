# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0] - 2026-10-28

### Added

- `Belay::OpenAIProvider`, calling either of OpenAI's current APIs
  (`api: :responses`, the default, or `api: :chat_completions`), with the
  same structured-output/cost/latency contract as `AnthropicProvider`.
- `Belay::GeminiProvider`, calling Google's Gemini API.
- `ActiveSupport::Notifications` instrumentation for the run/step/gate
  lifecycle (`belay.run.*`, `belay.step.completed`, `belay.step.needs_review`,
  `belay.gate.*`), so a host app can pipe what Belay is doing into its own
  logs/APM without polling the dashboard.

## [0.1.0] - 2026-10-27

### Added

- Workflow DSL (`input`, `step`, `gate`) and `Workflow.start`, which dedups on
  `idempotency_key:` at the run level.
- Durable execution: every step's output is checkpointed as its own database
  row, so a crashed run resumes from its last checkpoint instead of restarting.
- Crash recovery policy per step: `idempotent: true` resumes automatically;
  otherwise the orphaned step is flagged `needs_review` for a human to resolve
  via `run.resolve_needs_review!`.
- Gates: `gate :name, when:` pauses a run for a human decision via
  `run.approve!`/`run.reject!`, including an `edited_payload:` override.
- Rules: a gate approved consistently, and without edits, enough times
  (`rule_approval_threshold`, default 3) learns to auto-settle future identical
  occurrences without pausing for a human again.
- Replay: `run.replay(model:)` re-runs a completed run's model calls against a
  different model and returns a position-by-position `replay_diff`, without
  re-executing any other step or side effect.
- Caching: `ctx.llm(..., cacheable: true)` with a configurable `cache_ttl`.
- Crash-safety for in-flight runs: a lease-and-heartbeat mechanism
  (`lease_duration`, `heartbeat_interval`) plus a `JanitorJob` that reclaims
  and resumes any run whose worker died mid-step.
- Dashboard: a mountable Rails engine with a runs index (status/workflow
  filters, pagination), a per-run step timeline, a replay diff view, and a
  cost-over-time stats page - behind a configurable `authenticate_with` gate
  with no default that lets anyone through.
- Pluggable LLM provider interface (`Belay.config.provider`), shipping with an
  Anthropic provider.
