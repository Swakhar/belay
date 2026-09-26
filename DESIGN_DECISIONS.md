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

## 11. Phase 0 spike: proof that resume works

Before building the library, we built a throwaway Rails app (branch `spike/resume`, never merged) to answer one question: if a process is killed with `kill -9` in the middle of a run, does the run pick up at the right step when restarted?

The spike is deliberately tiny. A run has three hardcoded steps, and each step is one row in a `steps` table (`position`, `status`, `output`). Before a step's code runs, its row is committed as `started`. After the code returns, the row is updated to `succeeded` with the output. When a run is restarted, `succeeded` steps are skipped and a leftover `started` step is run again.

To test it, a script (`bin/spike_crash_test` on that branch) runs the steps in a separate OS process. The step at a chosen position runs its real code, which records one row in a separate `step_invocations` log table, and then sends itself SIGKILL before it can return. A second process then restarts the same run. SIGKILL gives the process no chance to clean up, so this is a real hard stop, not a raised exception.

### Result

In every scenario the restarted run finished with exactly three `succeeded` steps at positions 0, 1 and 2, with no duplicate and no missing row. The table shows how many times each step's code ran, against how many times it was checkpointed:

| Scenario | fetch_invoice | extract_total | book_payment |
|---|---|---|---|
| killed during step 0 | **2** ran / 1 checkpointed | 1 / 1 | 1 / 1 |
| killed during step 1 | 1 / 1 | **2** ran / 1 checkpointed | 1 / 1 |
| killed during step 2 | 1 / 1 | 1 / 1 | **2** ran / 1 checkpointed |
| not killed | 1 / 1 | 1 / 1 | 1 / 1 |

### Conclusion: at-least-once

Resume works: the checkpoints survive a hard kill and the run continues from the first unfinished step. But the step that was killed ran its code twice, once before the kill and once after the restart, while being checkpointed once. The kill landed after the side effect and before the output was written, and no database design can close that window. So delivery is **at-least-once**, and exactly-once holds only when the step's own side effect is idempotent. Decision 2 above is the response to this, and decisions 3 and 4 (a key that is stable across attempts, and no transaction held across the call) are what make the `started` row and a safe retry possible.

### What the spike did not test

It did not kill the process during the `started` insert itself, run two workers against one run, or use leases. The side effect was a local table insert, not an external API, so no idempotency key was actually honoured by anything. It also retries every leftover `started` step unconditionally. The rule in decision 2, where a non-idempotent step is flagged `needs_review` instead of being retried, is not implemented in the spike.
