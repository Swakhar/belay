# frozen_string_literal: true

require "rbconfig"
require "securerandom"
require "tmpdir"
require_relative "support/crash_test_workflow"

# Phase 0's spike (belay-planning/DECISIONS.md, "Phase 0 spike findings") proved this
# methodology against a hardcoded three-step executor in a throwaway app. This spec
# re-runs it against the real gem: a genuinely separate OS process is SIGKILLed mid-
# step (after its "started" row commits, before anything catches an exception for
# it), and a second process resumes the same run. :real_connections (see
# spec_helper.rb) opts these examples out of the per-example rollback wrapper every
# other spec gets - the child process's own connection can only see what this
# process actually committed, so rows have to be real, and these examples clean up
# their own.
RSpec.describe "crash and resume", :real_connections do
  def runner_path
    File.expand_path("support/crash_test_runner.rb", __dir__)
  end

  def spawn_runner(run, crash_at_position: nil)
    env = crash_at_position.nil? ? {} : { "CRASH_AT_POSITION" => crash_at_position.to_s }
    pid = Process.spawn(env, RbConfig.ruby, runner_path, run.id.to_s)
    Process.wait2(pid).last
  end

  # A plain path, not Tempfile.new(...).path: Tempfile registers a finalizer that
  # unlinks its backing file when the Tempfile OBJECT is GC'd - keeping only the
  # path string (as this test needs to, across several spawned child processes)
  # leaves nothing holding a live reference, so GC can delete the file out from
  # under a still-running child at an arbitrary moment. Confirmed as the actual
  # cause of a real, intermittent failure during this spec's own development (one
  # step's log line silently missing - the file had been unlinked and recreated
  # mid-run by a GC pass in THIS process, not a bug in the executor at all).
  def new_log_path
    File.join(Dir.tmpdir, "belay-crash-test-#{SecureRandom.uuid}.log")
  end

  def build_run(log_path)
    Belay::Run.create!(workflow: "CrashTestWorkflow", workflow_version: CrashTestWorkflow.workflow_version,
                       input: { invocation_log_path: log_path })
  end

  def invocation_counts(log_path)
    lines = File.readlines(log_path).map(&:strip)
    (0..2).map { |i| lines.count("step_#{i}") }
  end

  after do
    Belay::Step.where(run: @run).delete_all
    @run&.destroy
    File.delete(@log_path) if @log_path && File.exist?(@log_path)
  end

  [0, 1, 2].each do |position|
    it "resumes cleanly after a real SIGKILL mid-step at position #{position}" do
      @log_path = new_log_path
      @run = build_run(@log_path)

      first = spawn_runner(@run, crash_at_position: position)

      expect(first.signaled?).to be true
      expect(Signal.signame(first.termsig)).to eq("KILL")
      crashed_step = @run.steps.find_by(position: position)
      expect(crashed_step.status).to eq("started")

      second = spawn_runner(@run)

      expect(second.exitstatus).to eq(0)
      steps = @run.steps.order(:position).to_a
      expect(steps.size).to eq(3)
      expect(steps.map(&:status)).to all(eq("succeeded"))
      expect(@run.reload.status).to eq("completed")

      # At-least-once, not exactly-once (DESIGN_DECISIONS #2): the crashed step's body
      # ran once before the kill and once more on resume - everything else ran once.
      expected_counts = [1, 1, 1]
      expected_counts[position] += 1
      expect(invocation_counts(@log_path)).to eq(expected_counts)
    end
  end

  it "runs cleanly end to end with no crash injected, exactly once per step" do
    @log_path = new_log_path
    @run = build_run(@log_path)

    status = spawn_runner(@run)

    expect(status.exitstatus).to eq(0)
    expect(@run.steps.order(:position).pluck(:status)).to eq(%w[succeeded succeeded succeeded])
    expect(invocation_counts(@log_path)).to eq([1, 1, 1])
  end
end
