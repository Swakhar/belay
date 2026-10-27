# Rules

```ruby
Belay.configure { |config| config.rule_approval_threshold = 3 } # default
```

A gate approved consistently, and without edits, enough times learns a **rule** - a future occurrence with the exact same `(input, outputs)` and the exact same `when:` condition then auto-settles without ever pausing for a human. Nothing needs to be configured to opt in; it happens automatically from ordinary `approve!` calls, governed by `Belay.config.rule_approval_threshold` (default 3).

## Learning

Only an UNEDITED `approve!` (no `edited_payload:`) counts toward learning - editing the output is a human saying the gate's own answer wasn't quite right. A single `reject!` invalidates the matching rule immediately and permanently: no tolerance for "mostly consistent," and no re-learning afterward for that exact occurrence, no matter how many approvals arrive later.

## Auto-settling

An auto-settled gate's step row looks like an unedited human approval (`status: "succeeded"`, `output: nil`), except `rule_applied_id` is set and there's no `Belay::Approval` row - no human decided that one.

This is the one place in this gem that bypasses a human decision point entirely, so matching is scoped as tightly as possible: a rule learned under one `when:` condition cannot match a gate now running a different one, even with identical input/outputs, even if the gate kept the same name. See [DESIGN_DECISIONS.md #18](../DESIGN_DECISIONS.md) for why that distinction needs its own mechanism, separate from `workflow_version`, and for the honestly-documented residual limits of that mechanism.

See [gates.md](gates.md) for the rest of the approve!/reject! mechanics this builds on.
