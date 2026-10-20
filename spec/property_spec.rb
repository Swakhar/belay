# frozen_string_literal: true

require "rbconfig"
require "securerandom"
require "tmpdir"
require_relative "support/property_test_workflow"

# Generalizes spec/crash_spec.rb's single fixed 3-step fixture into a property:
# across workflows of DIFFERENT sizes, killing the real executor process at EVERY
# possible step boundary and resuming always converges to the mathematically
# correct final output - not just "completes successfully, with the right row
# count" (already proven, for one fixed size, by crash_spec.rb), but "produces the
# exact value a clean run would have, regardless of where it was interrupted."
# Exhaustive over small, bounded spaces (every position for a 1-step and a 4-step
# workflow) rather than randomized sampling - the state space here is small enough
# that exhaustive is both correct and simpler than reaching for a property-testing
# gem just for this.
#
# :real_connections (see spec_helper.rb) for the same reason spec/crash_spec.rb
# needs it: this spawns real OS processes, so rows have to be real commits.
RSpec.describe "crash/resume convergence", :real_connections do
  def runner_path
    File.expand_path("support/property_test_runner.rb", __dir__)
  end

  def spawn_runner(run, crash_at_position: nil)
    env = crash_at_position.nil? ? {} : { "CRASH_AT_POSITION" => crash_at_position.to_s }
    pid = Process.spawn(env, RbConfig.ruby, runner_path, run.id.to_s)
    Process.wait2(pid).last
  end

  def new_log_path
    File.join(Dir.tmpdir, "belay-property-test-#{SecureRandom.uuid}.log")
  end

  after do
    Belay::Step.where(run: @run).delete_all
    @run&.destroy
    File.delete(@log_path) if @log_path && File.exist?(@log_path)
  end

  PropertyTestWorkflows::SIZES.each do |size|
    describe "a #{size}-step workflow" do
      let(:workflow_class) { Object.const_get(:"PropertyTestWorkflow#{size}") }

      size.times do |crash_position|
        it "converges to the correct final output when killed at step #{crash_position}" do
          @log_path = new_log_path
          @run = Belay::Run.create!(workflow: workflow_class.name, workflow_version: workflow_class.workflow_version,
                                    input: { seed: 7, invocation_log_path: @log_path })

          first = spawn_runner(@run, crash_at_position: crash_position)
          expect(first.signaled?).to be true
          expect(Signal.signame(first.termsig)).to eq("KILL")

          second = spawn_runner(@run)
          expect(second.exitstatus).to eq(0)

          @run.reload
          expect(@run.status).to eq("completed")

          steps = @run.steps.order(:position).to_a
          expect(steps.size).to eq(size)
          steps.each_with_index do |step, position|
            expect(step.status).to eq("succeeded")
            expect(step.output).to eq(PropertyTestWorkflows.expected_output(position, 7))
          end
        end
      end
    end
  end
end
