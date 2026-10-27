# Replay

```ruby
shadow = run.replay(model: "claude-opus-5-5")  # a fresh, separate Run
shadow.replay_of   # => the original run
run.replays        # => [shadow, ...] - every replay of this run
shadow.replay_diff # => [{ position:, name:, kind:, original_output:, replay_output:, replayed:, changed: }, ...]
```

`run.replay(model: nil)` creates a shadow run and runs it for real: every `llm_call` step is re-executed against `model:` (or whatever model the step's own block already specified, if `model:` is omitted - either way, a real provider call, not a cached one), while every other step - plain Ruby, tool calls, and gate decisions alike - is served from `run`'s own recorded output, never re-executed.

DESIGN_DECISIONS #8: replay compares extractions; it does not book the invoice a second time.

Refuses (raises a clear `Belay::Error`, doesn't warn-and-proceed) if the workflow's current `workflow_version` doesn't match what `run` actually executed against - a changed step list makes any diff computed afterward meaningless, not just suspect.

## Diffing

`replay_diff` compares the shadow against the run it replayed, position by position: `changed` is a plain `!=` on the two outputs (not a deep diff of exactly what moved inside a Hash), and `replayed` distinguishes "never got this far" from "got here and didn't change" - a replay that fails partway through (a bad override model, a provider outage) leaves every later position with `replayed: false`.

## The mechanism

A `model:` override reaching the actual provider call, not just a workflow author's own hardcoded `model:` string, is the entire mechanism: `ctx.llm`'s `model:` argument becomes a default a replay's override replaces, invisibly to the step's own code.
