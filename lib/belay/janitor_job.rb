# frozen_string_literal: true

require "active_job"

module Belay
  # Finds runs stuck in "running" with no live lease - either the lease has expired,
  # or (today's realistic case, since Workflow.start still runs the executor inline,
  # not through ResumeRunJob) no lease was ever taken out before the process
  # crashed - and re-enqueues ResumeRunJob for each. Doesn't reclaim anything itself:
  # acquire_lease!'s conditional UPDATE is still the only thing that actually claims
  # a lease, so if this runs twice, or races a worker that's about to heartbeat, the
  # side that loses that race quietly no-ops (same as any other lease contention)
  # rather than the two stepping on each other.
  #
  # Deliberately leaves paused runs alone: a run paused via flag_needs_review! is
  # waiting on a human decision, not a crashed worker - re-enqueuing it would just
  # have ResumeRunJob acquire the lease and Executor hit the same needs_review step
  # again, achieving nothing. Only something that actually resolves the review (not
  # built yet) should move a paused run back to running.
  #
  # Nothing schedules this job on a recurring basis - that's a host app's concern
  # (cron, sidekiq-cron, whenever, etc.), not this gem's.
  #
  # Real gap, not just theoretical, on review: DESIGN_DECISIONS #12 sizes
  # lease_duration/heartbeat_interval assuming something heartbeats roughly every
  # heartbeat_interval while a step is in flight, so a live worker's lease never
  # actually goes stale under this job's nose. That per-step heartbeat loop doesn't
  # exist yet - Executor has no hook to call heartbeat_lease! from mid-step (same gap
  # ResumeRunJob's comment already names). Until it does, any step that runs longer
  # than lease_duration makes its own lease genuinely expire while its worker is
  # still inside it, and this job will legitimately reclaim it: a second
  # Executor.new(run).call then runs concurrently with the first, which can race the
  # same belay_steps row (one side's flag_needs_review! update colliding with the
  # other side's succeeded/failed update) rather than cleanly lose a lease-contention
  # check. Safe to run only once Executor exposes that per-step heartbeat hook, or
  # against workloads where no single step can plausibly run past lease_duration.
  class JanitorJob < ActiveJob::Base
    def perform
      stale_runs.find_each do |run|
        ResumeRunJob.perform_later(run.id)
      end
    end

    private

    def stale_runs
      Run.running.where("lease_owner IS NULL OR lease_expires_at < ?", Time.current)
    end
  end
end
