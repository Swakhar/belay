# frozen_string_literal: true

# A fixed 3-step workflow for spec/crash_spec.rb's real OS-process crash/resume test -
# mirrors the Phase 0 spike's bin/spike_crash_test methodology (see
# belay-planning/DECISIONS.md) against the real gem, not a hardcoded executor. Loaded
# by both the main RSpec process (to create the Run and compute workflow_version) and
# the child runner script (crash_test_runner.rb) spawned as a separate OS process, so
# both resolve the same CrashTestWorkflow constant by name - Executor#workflow_class
# does @run.workflow.constantize, which only works if this file is loaded wherever
# that happens.
#
# Each step logs its own invocation to a file (not a DB table - avoids a bespoke
# migration just for test instrumentation) before returning, so a resumed run's "did
# the crashed step's body actually run twice" claim is measured, not assumed, same as
# the spike's own invocation counts.
#
# idempotent: true on every step: the crash test's whole point is verifying that an
# orphaned "started" row left by a real SIGKILL gets automatically retried on resume,
# not flagged needs_review - these steps have no real side effect to worry about
# re-running (just a log line and a deterministic return value).
class CrashTestWorkflow < Belay::Workflow
  input :invocation_log_path

  3.times do |position|
    step(:"step_#{position}", idempotent: true) do |ctx|
      File.open(ctx.invocation_log_path, "a") { |f| f.puts("step_#{position}") }

      if ENV["CRASH_AT_POSITION"] == position.to_s
        Process.kill("KILL", Process.pid)
        sleep # unreached - KILL is unblockable and immediate
      end

      { position: position }
    end
  end
end
