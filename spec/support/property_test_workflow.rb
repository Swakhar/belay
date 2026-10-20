# frozen_string_literal: true

# Workflow families of varying step counts for spec/property_spec.rb's exhaustive
# crash-point sweep - see that file for why. Named as real top-level constants (not
# stub_const, which only exists inside RSpec and only for the duration of one
# example) for the same cross-process reason as crash_test_workflow.rb: a spawned
# child process resolves Belay::Executor#workflow_class via
# @run.workflow.constantize, which only works if this file defines the identical
# class by the identical name wherever it's loaded.
#
# Each step's output is a pure function of its own position and the run's seed
# input, computed identically in .expected_output below - deterministic and
# independently computable without ever actually running anything, which is what
# lets property_spec.rb assert convergence against a COMPUTED expectation rather
# than needing a separately-run "clean" baseline process per case.
module PropertyTestWorkflows
  SIZES = [1, 4].freeze

  def self.expected_output(position, seed)
    { "position" => position, "seed" => seed }
  end

  SIZES.each do |size|
    workflow_class = Class.new(Belay::Workflow) do
      input :seed
      input :invocation_log_path

      size.times do |position|
        step(:"step_#{position}", idempotent: true) do |ctx|
          File.open(ctx.invocation_log_path, "a") { |f| f.puts("step_#{position}") }

          if ENV["CRASH_AT_POSITION"] == position.to_s
            Process.kill("KILL", Process.pid)
            sleep # unreached - KILL is unblockable and immediate
          end

          PropertyTestWorkflows.expected_output(position, ctx.seed)
        end
      end
    end

    Object.const_set(:"PropertyTestWorkflow#{size}", workflow_class)
  end
end
