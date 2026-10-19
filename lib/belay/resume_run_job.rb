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
  # than erroring or forcing its way in. Nothing here heartbeats the lease while the
  # executor runs, or releases it afterward: both are real gaps for a run with many
  # steps or a long single step (see DESIGN_DECISIONS #12's 300s default - a step
  # slower than that outruns the lease with nothing renewing it), left for whenever
  # Executor exposes a per-step hook to call heartbeat_lease! from, which it doesn't
  # yet. JanitorJob (not built) reclaiming an expired lease is what currently
  # recovers from that, same as it recovers from a crash.
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
