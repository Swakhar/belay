# Roadmap

No dates. Ordered by dependency, not priority.

- **Core runtime** — workflow DSL, executor, checkpointing, leases and janitor, retries, Anthropic and fake providers, ActiveJob integration. *Done (`v0.1.0.pre1`).*
- **Gates and dashboard** — human approval steps, and a mountable engine showing runs, step timelines, tokens and cost. *Done.*
- **Dashboard UI** — the above shipped functional and unstyled; this is the visual pass (Tailwind, compiled and vendored - no asset-pipeline dependency on the host app). *Done.*
- **Replay** — re-run a recorded run against a different model or prompt and diff the outputs. *Done.*
- **Cost reduction** — opt-in exact-match response cache (`ctx.llm(..., cacheable: true)`), plus rules learned from consistent human gate approvals that auto-settle a matching future gate occurrence before ever pausing, plus a dashboard chart of real provider calls per 100 runs over time. *Done.*
- **1.0** — API stability commitment, once the above has been used in anger.

Not planned: streaming, non-Postgres databases, a prompt-templating DSL.
