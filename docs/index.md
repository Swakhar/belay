---
layout: home
title: Home
nav_order: 1
---

# Belay

Durable execution for AI agents in Rails.

Sidekiq gives you durable background jobs. Belay gives you durable *AI* jobs — every model call and tool call is a database row, so a run can crash at step 47 and resume at step 47.

It sits under whatever prompting style you use and records everything. It is not a prompt library, not a chain-builder DSL, and not a wrapper that hides your LLM SDK.

**Status:** early release (`v0.1.0`). Core runtime, gates & approvals, replay, caching & rules, and the dashboard are implemented and proven with real process kills and real concurrent workers, not just designed - see the [design decisions](https://github.com/Swakhar/belay/blob/main/DESIGN_DECISIONS.md).

## Where to start

- **[Gates and approvals](gates.md)** - pausing a run for a human, `approve!`/`reject!`, and `needs_review`'s crash-recovery pause.
- **[Rules](rules.md)** - how a consistently-approved gate learns to stop pausing.
- **[Replay](replay.md)** - re-running a completed run's model calls against a different model.
- **[Caching](caching.md)** - `cacheable: true` and when it's actually safe to use.
- **[Providers](providers.md)** - ships Anthropic, OpenAI, and Gemini providers; bring your own for anything else.
- **[Dashboard](dashboard.md)** - mounting the engine and wiring in your own auth.

For installation, configuration, and the full workflow DSL, see the [README](https://github.com/Swakhar/belay#readme).
