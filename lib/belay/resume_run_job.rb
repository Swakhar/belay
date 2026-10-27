# frozen_string_literal: true

require "active_job"

module Belay
  # Drives a run forward: acquire the lease, run the executor. Enqueue with
  # Belay::ResumeRunJob.perform_later(run.id) - nothing in this gem enqueues it yet
  # (Workflow.start runs the executor inline); this is the piece later work would
  # call to move that off the calling process.
  #
  # job_id is the lease owner: ActiveJob already gives every performed job a unique
  # one, so there's no separate owner-identity scheme to invent.
  #
  # If acquire_lease! fails, another worker already holds this run (or is between
  # attempts with time still left on its lease) - this job quietly returns rather
  # than erroring or forcing its way in. Nothing here heartbeats the lease itself -
  # Executor::StepRunner does, via Run#heartbeat_while, for as long as any single
  # step/gate is actually in flight (see DESIGN_DECISIONS #12/#13) - and nothing
  # releases it afterward either: a terminal run (completed/failed) is left holding
  # its lease, harmless today since every caller of acquire_lease! already scopes to
  # status: running first (see Run#release_lease!'s own comment). JanitorJob
  # reclaiming an expired lease is what recovers from a crash, or from a step
  # genuinely slower than heartbeat_while's own thread can keep renewing for.
  #
  # No retries: are configured on this class today, which matters because job_id is
  # NOT fresh across an ActiveJob-level retry - retry_job copies the failed attempt's
  # job_id onto the retried instance by design (only provider_job_id changes). If
  # retry_on were ever added here, a job that acquires the lease then raises before
  # the lease naturally expires would have its own retry see that still-valid lease
  # as "owned by job_id X" (itself) and quietly no-op instead of resuming, since
  # acquire_lease! has no same-owner bypass (that's heartbeat_lease!'s job). Adding
  # retry_on to this class would need to account for that; don't add it without
  # also handling same-owner reacquisition.
  class ResumeRunJob < ActiveJob::Base
    def perform(run_id)
      run = Run.find(run_id)
      return unless run.acquire_lease!(owner: job_id)

      Executor.new(run).call
    end
  end
end
