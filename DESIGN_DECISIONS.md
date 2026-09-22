# Design Decisions

Why Belay is built the way it is. Append-only: superseded entries are marked, not deleted.

---

## 1. A step is never re-executed once its output is checkpointed

This is the invariant everything else serves. Each step writes one row before it calls out and one row when it returns. Resume walks the run, finds the first step without a checkpointed output, and continues from there. No step bookkeeping lives in memory, so the worker is disposable.

## 2. Delivery guarantee: at-least-once, with exactly-once only for idempotent steps

A process can die after a side effect has happened but before its output is written — the payment is booked, then the worker is killed. No amount of database design removes that window, so Belay does not claim to.

What it does instead:

1. The step row is written as `started`, with a deterministic idempotency key, before the call leaves the process.
2. That key is exposed to your step body as `ctx.step_idempotency_key`, so you can pass it to any API that supports idempotency keys.
3. On resume, a step found in `started` is **not** blindly retried. If it is declared `idempotent: true` it is retried. Otherwise the run stops and the step is flagged `needs_review` for a human.

Steps that touch money or send mail should either be idempotent or expect to be reviewed. Belay makes that choice explicit instead of guessing.

## 3. The idempotency key is stable across attempts

`step_idempotency_key` is derived from the run id and the step position only — not the attempt number. A retry of the same step must present the same key to the external API, otherwise the retry is treated as a new request and the side effect happens twice.

Attempts are still recorded separately: `belay_steps` is unique on `[run_id, position, attempt]`, so you keep the full history of failures without weakening idempotency.

## 4. No database transaction is held across a network call

Each step is two transactions with the provider call in between: one to record `started`, one to record the outcome and advance the run. Wrapping the call in a single transaction would hold a connection open for the length of a model response and would make the `started` row invisible to the janitor — which defeats its purpose.

## 5. Leases are a column, not an advisory lock

A worker claims a run with a conditional `UPDATE` on `lease_owner` / `lease_expires_at`, and heartbeats while a step is in flight. A janitor job reclaims runs whose lease has expired.

Advisory locks would work, but they're invisible in a query, they vanish on connection loss in ways that are hard to reason about, and they can't be inspected from the dashboard. A column can be read, indexed, and shown in a UI.

## 6. Postgres only, for now

Belay leans on `jsonb` for step input and output. Supporting MySQL would mean a lowest-common-denominator schema for a gem whose entire value is what it stores. If you need MySQL, this is not the library today.

## 7. Gates are steps

A gate that pauses and a gate that is skipped both write a step row. If the outcome weren't checkpointed, a resume or a replay could re-evaluate the condition against a changed context and take a different branch than the one that actually ran. History has to be a record of what happened, not a re-derivation of it.

## 8. Replay does not repeat side effects

`run.replay(model: ...)` creates a shadow run that re-executes model calls against stored inputs. Tool and non-LLM steps are served from their recorded outputs, and recorded gate decisions are reused. Replaying an invoice run compares extractions; it does not book the invoice a second time.

Replay refuses to run when the workflow definition has changed in a way that makes the comparison meaningless.

## 9. No streaming in v1

Streaming and durability pull in opposite directions: a partial response that is never finished is not a checkpoint. Belay records complete responses. Streaming may come later, once the durable path is boring.

## 10. Caching applies to decisions, never to extracted values

The cache is opt-in and limited to steps whose output is a classification or a decision. Extracted numbers — totals, dates, account identifiers — are never served from cache, because two documents that produce the same prompt hash are not guaranteed to be the same document.
