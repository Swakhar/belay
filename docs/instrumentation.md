---
layout: default
title: Instrumentation
nav_order: 8
---

# Instrumentation

Without this, the only way to know what Belay is doing is to look at the dashboard. Belay publishes [`ActiveSupport::Notifications`](https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html) events for the run/step/gate lifecycle - the same mechanism Rails itself uses for `sql.active_record` and `process_action.action_controller` - so a host app can pipe them into its own logs, Datadog, Honeycomb, Sentry, or anything else, without polling.

```ruby
ActiveSupport::Notifications.subscribe(/^belay\./) do |name, _start, _finish, _id, payload|
  Rails.logger.info("[belay] #{name} #{payload.inspect}")
end
```

Every payload includes `run_id:`; most include a `step_id:`/`name:` for whichever step or gate the event is about.

## Run events

| Event | Fires when | Payload |
|---|---|---|
| `belay.run.started` | `Run#start!` (pending → running) | `run_id:, workflow:, workflow_version:, from:, to:` |
| `belay.run.paused` | `Run#pause!` - a gate pausing for approval, or a step flagged `needs_review`, both pause the run this same way | same |
| `belay.run.resumed` | `Run#resume!` (paused → running) - including via `approve!` and `resolve_needs_review!`'s `succeeded` outcome | same |
| `belay.run.completed` | `Run#complete!` | same |
| `belay.run.failed` | `Run#fail!` - including a rejected gate | same |
| `belay.run.cancelled` | `Run#cancel!` | same |

A rejected transition (`InvalidTransitionError`) instruments nothing - the event always means the transition actually happened, same guarantee `sql.active_record` gives for a query that actually ran.

## Step events

| Event | Fires when | Payload |
|---|---|---|
| `belay.step.completed` | every settled attempt of a step or gate - success and failure alike, `status:` tells you which | `run_id:, step_id:, position:, name:, kind:, status:, attempt:` |
| `belay.step.needs_review` | an orphaned `started` row isn't `idempotent: true` and gets flagged for a human | `run_id:, step_id:, name:, reason:` |

One event per settled attempt, not separate started/completed events - a step declared `retries:` fires this once per attempt, the same way it gets its own `Step` row per attempt.

## Gate events

| Event | Fires when | Payload |
|---|---|---|
| `belay.gate.paused` | `when:` evaluates true and no [rule](rules.md) auto-approves it | `run_id:, step_id:, name:` |
| `belay.gate.auto_approved` | `when:` evaluates true and an active rule settles it without pausing | `run_id:, step_id:, name:, rule_id:` |
| `belay.gate.approved` | `run.approve!` | `run_id:, step_id:, name:, by:, edited:` (`edited:` is `true` when `edited_payload:` was given) |
| `belay.gate.rejected` | `run.reject!` | `run_id:, step_id:, name:, by:` |

## A subscriber's own exceptions

`ActiveSupport::Notifications` calls subscribers synchronously, in-process - same as any other Rails instrumentation. A subscriber that raises will propagate that exception back into the Belay code that fired the event. Keep subscribers fast and defensive (catch your own errors before they escape), the same way you would for any other Rails notification.
