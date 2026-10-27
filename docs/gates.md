---
layout: default
title: Gates and approvals
nav_order: 2
---

# Gates and approvals

```ruby
gate :approval, when: ->(ctx) { ctx.extract[:total_cents] > 100_00 } # true pauses for a human

run.status        # => "paused" if the gate's when: was true; "completed" if every gate skipped
run.pending_gate  # the awaiting_approval Belay::Step, or nil if nothing's paused on a gate
run.approve!(by: current_user.email) # resumes the run past the gate, via ResumeRunJob
run.approve!(by: current_user.email, edited_payload: { total_cents: 42_00 }) # becomes ctx.approval downstream
run.reject!(by: current_user.email)  # fails the run outright - nothing to resume into
```

## How a gate is checkpointed

`when:` is evaluated with the step's own context (prior outputs included), same as any step's block.

- **`when:` false** checkpoints the gate `skipped` (DESIGN_DECISIONS #7, "gates are steps" - a gate shares the same ordered list and resume/retry machinery `step` does, not a separate path) and the run continues past it. Resuming a run that already has a skipped gate reuses that row without re-evaluating `when:`.
- **`when:` true** checkpoints the gate `awaiting_approval`, pauses the run, releases its lease, and stops - no further steps run, and `run.pending_gate` finds that step. Unless a learned rule already matches this exact occurrence - see [rules.md](rules.md) - in which case it auto-settles instead of pausing.

## Resolving a pending gate

`run.approve!(by:, edited_payload: nil)` records a `Belay::Approval` (status `"approved"`, `decided_by: by`, `decided_at: Time.current`), settles the gate step `"succeeded"` (not `"skipped"` - that's reserved for `when:` false; this is `when:` true plus a human sign-off, a meaningfully different outcome), resumes the run, and enqueues `ResumeRunJob` to continue past it.

`run.reject!(by:)` records an `Approval` with status `"rejected"`, settles the gate `"failed"` (there's no separate "rejected" step status), and fails the run directly rather than enqueueing anything - there's no step to resume into once a gate is rejected.

Both raise a clear `Belay::Error` if the run has no pending gate. `by:` is written as-is to a plain string column (`decided_by`) - pass something meant to be read back later (an email, a username, an id), not a full user object.

`approve!`'s `edited_payload:` becomes the gate step's own output (gates settled via `when:` never have one - only their status changes), readable by any later step the same way it reads any other step's output: `ctx.<gate name>`. It's a deliberately narrower feature than "edit the data the gate's `when:` actually depended on" - the DSL has no declared link between a gate and which step(s) fed its condition, so there's no single other row this could unambiguously override instead. The edited value is also recorded on the `Approval` itself, so a dashboard can show what was edited without reaching through the gate's own output.

## `needs_review`: a different kind of pause

A step is never re-executed once its output is checkpointed. A step's block raising is caught, marked failed with the error recorded, and retried up to `retries:` times before propagating. A step orphaned by a crash (found `started`, no exception ever caught) is resumed automatically only if declared `idempotent: true`; otherwise it's flagged `needs_review`, the run is paused, and the step's own block never runs again until a human resolves it.

```ruby
run.pending_needs_review # the needs_review Belay::Step, or nil if nothing's flagged
run.resolve_needs_review!(by: current_user.email, outcome: "succeeded", output: { total_cents: 42_00 })
run.resolve_needs_review!(by: current_user.email, outcome: "failed") # fails the run outright, same as reject!
```

`outcome: "succeeded"` settles the step with whatever `output:` is supplied (there's no real one to recover - the block never returned one), resumes the run and enqueues `ResumeRunJob`, the same shape as `approve!`. `outcome: "failed"` settles it failed and fails the run directly, the same shape as `reject!` - deliberately never resuming into the executor's own retry logic, which could either raise uncaught (a step with no `retries:` left) or silently re-execute the block (a step with `retries:` left that hadn't exhausted them yet - exactly the side effect a human just confirmed did NOT happen).

No `Belay::Approval` row for a `needs_review` resolution - that model is scoped to gates specifically, including its unique-per-gate-step index; `belay_steps` has its own `resolved_by`/`resolved_at` columns instead, claimed with a conditional `UPDATE` rather than a unique-index collision, since there's no separate row to collide on for this kind of resolution.

See [DESIGN_DECISIONS.md](../DESIGN_DECISIONS.md) for the delivery guarantee (at-least-once, exactly-once only for idempotent steps - decision #2, proven against the real gem with real process kills and real concurrent workers by decision #13) and the reasoning behind the rest of the design.
