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

**Built in Phase 3, exactly as above, with no change to the policy - only to what it took to actually guarantee it.** `Run#replay(model:)` pre-seeds every non-`llm_call` step's recorded output into the shadow run *before* the executor ever runs it, then hands the shadow to the real, unmodified `Executor` - a gate needs no special-casing, it's just another step `kind:` that isn't `"llm_call"`. `Context#llm` gained a `model_override:`, threaded through from the shadow's own `replay_model` column, so a replayed `llm_call` step's hardcoded `model:` in the workflow body becomes a default the override replaces, invisibly to the workflow author.

Getting "does not repeat side effects" to actually hold took two real fixes, not just the design above: an unresolved non-llm step (an ordinary failure, or a rejected gate) is seeded as `needs_review`, not `failed` - a pre-seeded `"failed"` row's fate depends on the *current* workflow's `retries:` option, which `workflow_version` deliberately doesn't hash, so a step gaining `retries:` between when it ran and when it's replayed could make the executor silently re-run it for real; `needs_review`'s raise has no such dependency, so it's deterministic regardless. And the decision to re-run a step fresh vs. serve it from its recorded output checks the *current* workflow's declared `kind:` first, falling back to the original run's recorded kind only when the author declared none at all on either version - which `workflow_version` can't fully protect against either, since it hashes declared kind, not runtime behavior, by design. Both fixes, and the residual limitation the second one leaves, are described in full in `lib/belay/run.rb`'s own comments on `seed_recorded_steps!` and `llm_position?`.

## 9. No streaming in v1

Streaming and durability pull in opposite directions: a partial response that is never finished is not a checkpoint. Belay records complete responses. Streaming may come later, once the durable path is boring.

## 10. Caching is opt-in per call (`cacheable: true`), not inferred from step kind

Originally specified as "caching applies to decisions, never to extracted values" - but `kind: "llm_call"` covers both a classification call and an extraction call indistinguishably, so there's no mechanical way to tell them apart and restrict caching to one automatically. Caching is instead `ctx.llm(..., cacheable: true)`, an explicit per-call opt-in - the same contract `idempotent: true` already uses elsewhere in this gem: a policy enforced by author discipline, not by the framework. The underlying caution survives unchanged: only set `cacheable: true` on a call whose entire prompt text fully and uniquely determines the correct answer. A short, self-contained classification prompt usually qualifies; an extraction prompt that references a large document (especially over a vision/file attachment, whose bytes aren't part of what gets hashed) usually doesn't - two different documents could share a cache key and get back the wrong answer.

The cache key is `SHA256([provider class, model, prompt, schema].inspect)` - exact, literal match only, deliberately not normalized (symbol- vs. string-keyed `prompt`/`schema` hash differently, on purpose: "exact-match cache" means exactly that). A response is only ever cached after schema validation succeeds, so a `cacheable: true` key can never get stuck replaying a response that failed validation. `Belay.config.cache_ttl` (default 7 days, `nil` means never expires) is one global setting, not a per-call override.

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

## 12. Default lease duration is 300s, heartbeat interval is 30s

Decision 5 describes the lease mechanism (a column, heartbeated, reclaimed by a janitor) but not durations. A lease has to outlive the slowest expected step — a model call that takes tens of seconds — without staying claimed so long after a crash that a run looks stuck. 300 seconds is generous enough for a slow LLM call plus retries; 30 seconds gives a live worker ten heartbeats of margin before the janitor would consider the lease expired, so ordinary scheduling jitter never causes a false reclaim. Both live on `Belay::Configuration` and are overridable; both are now read by `Run#acquire_lease!`/`#heartbeat_lease!` and `JanitorJob` (Phase 1f).

## 13. Delivery guarantees are proven against the real gem, not just designed

Decision 2 stated the guarantee (at-least-once, exactly-once only for `idempotent: true` steps) and decision 11 proved it against a throwaway spike. By the end of Phase 1 it's proven against the real gem itself:

- **At-least-once, including real process death.** `spec/crash_spec.rb` SIGKILLs a real OS process mid-step, after its `started` row commits, and resumes in a second process — for every boundary of a 3-step workflow. `spec/property_spec.rb` generalizes this across workflows of different sizes (1 and 4 steps) and every possible crash position, asserting not just "it completes" but that the final output is the exact value a clean run would have produced, regardless of where it was interrupted.
- **Exactly-once only when declared.** The same crash tests use `idempotent: true` steps throughout, so they prove the *resumed* half of decision 2's claim; `needs_review` — the other half, for a step that crashes without that declaration — has its own dedicated coverage in `executor_spec.rb` (a non-idempotent orphaned `started` row is flagged, not retried, and the run pauses).
- **Only one worker advances a run at a time.** `spec/concurrency_spec.rb` races two workers through the real caller (`ResumeRunJob`), each with its own database connection, and proves exactly one of them ever gets far enough to construct an `Executor` at all — not just that `Run#acquire_lease!`'s SQL is atomic in isolation (`run_spec.rb` already covered that), but that the real integration honors it under genuine concurrent contention.

What's still *not* covered, stated plainly rather than implied by the tests' silence: nothing heartbeats a lease mid-step yet, so a single step slower than `lease_duration` (300s default) can have its lease legitimately reclaimed by `JanitorJob` while the original worker is still running — a real, documented gap (see `lib/belay/janitor_job.rb`'s and `lib/belay/resume_run_job.rb`'s own comments), not something these tests exercise. Nothing releases a lease on a terminal run either. `Workflow.start`'s run-level `idempotency_key` dedup is implemented and unit-tested, but not exercised by these crash/concurrency tests specifically.

## 14. The dashboard has no identity of its own, and defaults to locked

`Belay::Engine` is a real, isolated `Rails::Engine` with exactly one authentication hook: `Belay.config.authenticate_with`, a `->(request) { boolean }` proc. It has no default that lets anyone through — mounting the engine without configuring one raises on the very first request instead of quietly serving an open dashboard. This matters more than it would for a typical admin panel: the dashboard shows prompts, responses, costs, and the actions below that can approve, reject, or resolve a paused run. A library shouldn't guess that an operator remembered to lock this down.

The same hook only ever answers "is this request allowed," never "who is asking." Belay has no current-user concept of its own, and isn't trying to build one — every dashboard action that records who did something (`approve!`, `reject!`, `resolve_needs_review!`) takes a plain `by:` field instead. An admin dashboard with no identity layer can't honestly claim to know who clicked a button, so it doesn't pretend to; it asks.

## 15. Approvals are a gate concept; resolving `needs_review` is a different one

`Belay::Approval` exists for one thing: recording a decision on a gate's `awaiting_approval` step, enforced by a unique index on `step_id` — one approval per gate, ever. Resolving a step flagged `needs_review` (orphaned by a crash, not declared `idempotent: true`) is a different kind of human intervention and doesn't reuse it. `belay_steps` carries its own `resolved_by`/`resolved_at` columns instead, with the same double-resolve race closed by a conditional `UPDATE` rather than a unique-index collision — there's no second row here to collide on.

This is two different race-safety mechanisms for two different situations, not an inconsistency. A gate's decision is itself interesting data worth its own audit row (what was approved, with what edited payload). A `needs_review` resolution is an operational correction to history — there's nothing to approve, only a crash to account for.

## 16. A rejected gate or a failed `needs_review` resolution never resumes the run

`Run#reject!` and `Run#resolve_needs_review!(outcome: "failed")` both fail the run directly and synchronously, in the same transaction as the step's own settle — neither ever hands the run back to the executor. Resuming a rejected or failed row through the ordinary retry path would do one of two bad things: raise uncaught inside a background job with no rescue (a step with no `retries:` left), or silently re-execute the step's block (a step with `retries:` left that hadn't exhausted them yet) — exactly the side effect a human just confirmed didn't happen. Failing the run outright sidesteps both at once, for the same reason a crash should never leave a run quietly stuck resuming forever: a paused run should either move forward on purpose or stop, never drift.

## 17. The dashboard's CSS is compiled and vendored, never served through a host app's asset pipeline

Phase 2 shipped the dashboard functionally complete but entirely unstyled — a deliberate scope boundary at the time, not an oversight, but not something to present to anyone either. The fix is Tailwind, but *how* it's delivered follows the same rule every other part of this gem already follows: never assume anything about how the host app is configured. Belay doesn't assume Zeitwerk (every plain Ruby class is `require_relative`'d), doesn't assume a particular `load_defaults` version, draws its routes from the engine's own `config/routes.rb` rather than host convention. A host app's asset pipeline — Sprockets, Propshaft, or nothing at all — is exactly the same category of thing.

So the compiled CSS (`app/assets/belay/application.css`, built by a `package.json`/`tailwindcss` CLI step that's dev-only tooling for this gem's own contributors, never a runtime dependency) is inlined directly into the layout via a `<style>` tag (`Belay::Engine.stylesheet`), not linked. No host app's asset configuration can break it, because none is ever consulted.

The design system itself is deliberately small and centralized rather than ad hoc: one helper (`status_badge`) decides what every status looks like, grouped by what it *means* (done-and-fine, stopped-and-waiting-on-a-human, done-and-not-fine, in-progress) rather than by its literal string value, since a `Run` and a `Step` have six different, overlapping-in-meaning statuses with no shared class to hang this on otherwise. A fixed set of button/field component classes (`tailwind/application.css`'s `@layer components`) is reused by every form on every page. The goal in both cases is the same: a change to what "amber" means, or what a button looks like, happens in one place, not wherever a view author last typed out a utility-class string.

## 18. Rules: learned gate auto-approval, scoped to the exact occurrence it was learned from

A rule is learned from `Belay.config.rule_approval_threshold` (default 3) consistent, *unedited* human `approve!`s of the same gate occurrence - an approval with an `edited_payload:` doesn't count, since editing the output is a human saying the gate's own answer wasn't quite right. A single `reject!` invalidates the matching rule immediately and permanently, with no tolerance for "mostly consistent" and no re-learning afterward for that exact occurrence. Once active, a rule lets a later, identical gate occurrence auto-settle - succeeded, no `Belay::Approval` row, since no human decided that one - without ever pausing. This is the one mechanism in this gem that bypasses a human decision point entirely, so its matching is scoped as narrowly as this gem can make it: identity is `(workflow, workflow_version, gate_name, context_key)`, where `context_key` is a SHA256 hash of both the exact `[input, outputs]` the gate's `when:` was evaluated against *and* a fingerprint of the `when:` condition itself (its `source_location` - a `Proc`/`Method`'s file and line).

The condition fingerprint exists because `Workflow.workflow_version` deliberately hashes only step/gate names and kinds, never their options (decision #1's neighbor, effectively) - so rewriting a gate's `when:` entirely, while keeping its name and the workflow's other steps unchanged, wouldn't change `workflow_version` at all. Without the fingerprint, a rule learned from real human approvals under an OLD condition could silently auto-settle a future occurrence running a NEW, never-reviewed one, for any `(input, outputs)` that happened to recur - exactly the kind of bypass this feature exists to never produce. `source_location` was chosen over hashing the condition's own `#inspect` specifically because a `Proc`'s default `#inspect` embeds its `object_id` (a memory address), which changes on every process restart even with zero code changes - that would make every rule stop matching after every deploy. This isn't airtight: an in-place single-line lambda-body edit that doesn't move which line it starts on, or a parameterized factory reused with a different argument (`when: threshold_gate(100)` → `threshold_gate(200)`), doesn't move the literal and isn't caught. Closing that fully would mean hashing the condition's actual logic, which Ruby has no general way to do - the fingerprint catches the realistic case (any edit that adds, removes, or moves a line) without reintroducing the deploy-time false-invalidation problem it was chosen to avoid.
