# Belay — Decisions Log

Append-only. Each entry: date, decision, reason. Supersede, don't edit.

---

## 2026-09-22 — Name: Belay

- Gem name `belay` (free on RubyGems as of today), module `Belay`, base class `Belay::Workflow`.
- Replaces working name `durable_agent` / `DurableAgent` everywhere in the spec.
- Tables are prefixed `belay_` (`belay_runs`, `belay_steps`, `belay_approvals`, `belay_cache_entries`, `belay_rules`) instead of `agent_*`, so they can't collide with a host app's own "agent" tables.
- Why the name fits: a belay is the rope system that catches a climber when they fall and lets them continue from where they were. That is the product.

## 2026-09-22 — Spec corrections (found while reading the architecture doc)

1. **Idempotency key must not include `attempt`.** The spec defines `agent_steps.idempotency_key` as `run_id + position + attempt`, but that key is also the one passed to Stripe and other APIs. If it changes per attempt, a retry books the payment twice. Decision: `step_idempotency_key = run_id + position` (stable across attempts). Row uniqueness stays on `[run_id, position, attempt]`.
2. **Two transactions per step, not one.** "Write started row before the call" means that row has to commit before the external call, so each step is: txn 1 (insert `started`), external call outside any txn, txn 2 (write output, advance position). Never hold a DB transaction open across a network call.
3. **`workflow_version` hashes structure, not block bodies.** Ruby block source can't be hashed reliably. Hash step names, kinds, order and options. Mid-run version changes need a policy (proposed: finish on the old definition only if remaining steps match by name; otherwise mark run failed with a clear error).
4. **Gates are checkpointed too.** A gate whose `when:` is false is written as a `skipped` step row, so resume and replay never re-evaluate it with different context.
5. **Replay must not repeat side effects.** Shadow runs serve tool/non-LLM steps from recorded outputs by default and reuse recorded gate decisions. Otherwise replaying an invoice run re-books it.

## Open (from spec section 10) — proposed, not yet final

| # | Question | Proposal |
|---|---|---|
| 1 | Minimums | Ruby 3.2+, Rails 7.1+ |
| 2 | Databases | Postgres only for v1, stated plainly in README |
| 3 | Lease mechanism | `lease_expires_at` column + conditional UPDATE |
| 4 | Streaming in v1 | No |
| 5 | License | MIT |
