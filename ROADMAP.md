# Roadmap

No dates. Ordered by dependency, not priority.

- **Core runtime** — workflow DSL, executor, checkpointing, leases and janitor, retries, Anthropic and fake providers, ActiveJob integration. *In progress.*
- **Gates and dashboard** — human approval steps, and a mountable engine showing runs, step timelines, tokens and cost.
- **Replay** — re-run a recorded run against a different model or prompt and diff the outputs.
- **Cost reduction** — opt-in response cache for decision steps, plus learned rules checked before any provider call.
- **1.0** — API stability commitment, once the above has been used in anger.

Not planned: streaming, non-Postgres databases, a prompt-templating DSL.
