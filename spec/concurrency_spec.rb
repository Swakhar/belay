# frozen_string_literal: true

# DESIGN_DECISIONS #5 claims a worker claims a run with a conditional UPDATE that two
# workers racing on the same row can't both win. run_spec.rb already proves the SQL
# primitive (#acquire_lease!) in isolation, called sequentially from one connection -
# this spec proves the actual claim: two independent workers, each with their own
# real database connection, racing on the SAME run through the real caller
# (Belay::ResumeRunJob), not just the primitive underneath it. :real_connections (see
# spec_helper.rb) is required for the same reason spec/crash_spec.rb needs it: a
# second real connection (here, a Thread paired with
# ActiveRecord::Base.connection_pool.with_connection, not a spawned OS process - this
# mechanism doesn't need a second process, just a second connection) can only see
# rows this process has actually committed.
RSpec.describe "concurrent workers advancing a run", :real_connections do
  before do
    stub_const("ConcurrencySpecWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:a) { |ctx| { seen: ctx.invoice_id } }
      step(:b) { |_ctx| "b" }
      step(:c) { |_ctx| "c" }
    end)
  end

  after do
    Belay::Step.where(run: @run).delete_all
    @run&.destroy
  end

  it "lets exactly one of two simultaneous workers actually execute the run" do
    @run = Belay::Run.create!(workflow: "ConcurrencySpecWorkflow",
                              workflow_version: ConcurrencySpecWorkflow.workflow_version,
                              input: { invoice_id: 42 })

    # A two-phase barrier, not a fixed sleep: each thread signals ready BEFORE
    # blocking on go, and the main thread doesn't push anything onto go until it
    # has received both ready signals - so neither thread can be released until
    # BOTH are already confirmed blocked waiting for it. A sleep-then-release
    # version of this (tried first) only hopes the sleep was long enough for both
    # threads to reach the gate; under real scheduling delay (a loaded CI runner,
    # a GC pause) a slow-to-start thread could miss the window entirely and run
    # fully after the other one finishes - sequential, not concurrent, invisibly
    # still passing every assertion below. This can't degrade that way: the main
    # thread provably cannot release either thread until both have already
    # reached the gate.
    ready = Queue.new
    go = Queue.new
    jobs = Array.new(2)
    errors = Array.new(2)
    threads = Array.new(2) do |i|
      Thread.new do
        ready << :ready
        go.pop
        ActiveRecord::Base.connection_pool.with_connection do
          jobs[i] = Belay::ResumeRunJob.new(@run.id)
          jobs[i].perform_now
        end
      rescue StandardError => e
        errors[i] = e
      end
    end
    2.times { ready.pop }
    2.times { go.push(:go) }
    threads.each(&:join)

    expect(errors).to eq([nil, nil])
    @run.reload
    expect(@run.status).to eq("completed")
    # Exactly 3 rows, not 6: if both workers had slipped past the lease and both run
    # Executor#call, the second one's Step.create! for an already-taken
    # [run_id, position, attempt] would collide with the unique index - this would
    # either raise (caught above, as a non-nil error) or, if timing somehow avoided
    # that, leave duplicate/corrupted rows. Checking the exact count catches either.
    expect(@run.steps.order(:position).pluck(:name)).to eq(%w[a b c])
    # Whichever worker's acquire_lease! won is the one and only one that ran
    # Executor#call at all - ResumeRunJob#perform returns immediately on a lost
    # lease, before ever constructing an Executor. The run completing with exactly
    # 3 rows already proves this; this just names which worker it was.
    expect(@run.lease_owner).to be_in(jobs.map(&:job_id))
  end
end
