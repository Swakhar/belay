# frozen_string_literal: true

module Belay
  class Run < ApplicationRecord
    self.table_name = "belay_runs"

    has_many :steps, class_name: "Belay::Step"
    has_many :approvals, class_name: "Belay::Approval"

    # validate: false (the default) raises ArgumentError immediately on an invalid value,
    # rather than deferring to a validation error at save time. Right for internal state
    # management, which should fail loudly - but if status is ever set from unsanitized
    # external input (a form, an API param), that ArgumentError is unhandled, not a
    # friendly 422. Nothing does that today.
    enum :status, {
      pending: "pending",
      running: "running",
      paused: "paused",
      completed: "completed",
      failed: "failed",
      cancelled: "cancelled"
    }

    validates :workflow, presence: true
    validates :workflow_version, presence: true

    def start!
      transition!(from: "pending", to: "running", started_at: Time.current)
    end

    def pause!
      transition!(from: "running", to: "paused")
    end

    def resume!
      transition!(from: "paused", to: "running")
    end

    # None of complete!/fail!/cancel! below clear lease_owner/lease_expires_at - a
    # terminal run can be left holding a lease forever. Harmless today only because
    # every caller of acquire_lease! (JanitorJob, Phase 1f) scopes to status: running
    # first, so a stale lease on a terminal run is never actually read. Would need
    # fixing if anything ever queries leases without that status filter.
    def complete!
      transition!(from: "running", to: "completed", finished_at: Time.current)
    end

    def fail!(error: nil)
      transition!(from: %w[pending running paused], to: "failed", finished_at: Time.current, error: error)
    end

    def cancel!
      transition!(from: %w[pending running paused], to: "cancelled", finished_at: Time.current)
    end

    # At most one, by construction: Executor stops at the FIRST gate whose when:
    # evaluates true (throw :gate_paused unwinds immediately, no further steps
    # run), so a run can never have more than one step awaiting_approval at once.
    # nil, not a raise, when there isn't one - that's the common case (most runs
    # never pause on a gate at all), not an error condition.
    def pending_gate
      steps.awaiting_approval.first
    end

    # DESIGN_DECISIONS #5: "a worker claims a run with a conditional UPDATE on
    # lease_owner/lease_expires_at." The condition - no owner yet, or the existing
    # lease has expired - is evaluated by Postgres in the same statement that claims
    # it, not read-then-written from Ruby: two workers racing here can't both see
    # "unclaimed" and both proceed, the way the transition! comment above says two
    # workers racing on status can. update_all's return value (rows actually
    # matched) is the only thing this trusts; the in-memory object is reloaded only
    # after a successful claim, never used to decide one.
    #
    # Only claims the lease - callers (ResumeRunJob et al, not built yet) are
    # responsible for actually using it to serialize execution, and for releasing or
    # heartbeating it (Phase 1f's next commits). Nothing here calls this yet either.
    # Named with ! like start!/pause!/transition! above, not acquire_lease? - it's a
    # mutator that also reports success, which is the pattern this class already
    # uses for state changes. Diverges from those methods in one way: they raise on
    # an invalid transition, this returns false on lost contention - contention is
    # an expected, normal outcome here, not a bug to raise about.
    def acquire_lease!(owner:, duration: Belay.config.lease_duration) # rubocop:disable Naming/PredicateMethod
      expires_at = Time.current + duration
      claimed = self.class
                    .where(id: id)
                    .where("lease_owner IS NULL OR lease_expires_at < ?", Time.current)
                    .update_all(lease_owner: owner, lease_expires_at: expires_at)

      return false unless claimed == 1

      reload
      true
    end

    # DESIGN_DECISIONS #5: "...and heartbeats while a step is in flight." Extends
    # lease_expires_at by a fresh full duration, not by heartbeat_interval -
    # how often a caller heartbeats and how long each renewal buys are different
    # numbers (Belay.config has both; this method only uses lease_duration, same
    # default as acquire_lease!).
    #
    # Only renews a lease that's both owned by this caller AND not yet expired - if
    # it already expired, another worker may have already reclaimed it via
    # acquire_lease!, and blindly extending would fight that worker rather than
    # detect the conflict. A caller that discovers its own heartbeat failing should
    # treat that as "I may have lost this run," not retry the heartbeat.
    def heartbeat_lease!(owner:, duration: Belay.config.lease_duration) # rubocop:disable Naming/PredicateMethod
      expires_at = Time.current + duration
      renewed = self.class
                    .where(id: id, lease_owner: owner)
                    .where("lease_expires_at >= ?", Time.current)
                    .update_all(lease_expires_at: expires_at)

      return false unless renewed == 1

      reload
      true
    end

    # Unconditional, unlike acquire_lease!/heartbeat_lease! - both take an owner:
    # and defend against racing another worker; this doesn't check who (if
    # anyone) currently holds the lease. That's an honest limitation of what's
    # wired up today, not a deliberate safety choice: Executor/StepRunner, the
    # only caller so far (evaluate_gate!, pausing on a true gate), has no owner
    # identity of its own to check against - it's constructed as
    # Executor.new(run), with no owner: ever threaded through from whichever job
    # (if any) called it. Revisit if that changes; for now this just clears
    # whatever is there.
    def release_lease! # rubocop:disable Naming/PredicateMethod
      update!(lease_owner: nil, lease_expires_at: nil)
      true
    end

    # Approves this run's pending gate: records an approved Belay::Approval, settles
    # the gate step "succeeded" (not "skipped" - that's reserved for when: false;
    # this row's when: was true and a human signed off, a meaningfully different
    # outcome worth distinguishing on the dashboard/audit trail), resumes the run,
    # and enqueues ResumeRunJob to pick back up at the step right after the gate.
    #
    # by: is written as-is to decided_by (a plain string column) - ActiveRecord
    # coerces it via #to_s, so passing a full User object stores its #to_s, not a
    # useful identifier. Callers should pass something already meant to be read
    # back later (an email, a username, an id) - this method doesn't guess which.
    #
    # All three writes - the Approval, the gate's own status, and resume! - are
    # wrapped in one transaction, same reasoning as evaluate_gate!'s own fix: a
    # crash between them must not leave a gate no longer awaiting_approval (so a
    # second approve!/reject! would be guessing what already happened) while the
    # run is still paused, or vice versa. If the process dies after this
    # transaction commits but before ResumeRunJob.perform_later below enqueues,
    # the run is left "running" with no lease - exactly what JanitorJob's
    # stale-run query already reclaims (lib/belay/janitor_job.rb), so it isn't
    # actually orphaned, just picked up a cycle late.
    #
    # pending_gate is checked once, in memory, before the transaction - not a
    # row lock. Two callers racing to approve!/reject! the same gate (a double
    # click, two reviewers) can both pass that check; the DB's unique index on
    # belay_approvals.step_id is what actually decides it, and the loser's
    # approvals.create! raises ActiveRecord::RecordNotUnique, rolling back its
    # own transaction cleanly (the gate/run writes never ran) - rescued below
    # into the same kind of error a late pending_gate.nil? check would have
    # given a strictly-sequential second call, rather than a raw DB exception.
    #
    # edited_payload:, if given, becomes the gate step's own output - a gate
    # settled via evaluate_gate! never has one (only its status changes), so
    # this is the first thing that gives one a real output. A step after the
    # gate can read it back the same way it reads any other step's output:
    # ctx.<gate name>. This is a deliberate, narrower choice than "edit the
    # step the gate's when: actually depended on" - the DSL has no declared
    # link between a gate and which step(s) fed its condition, so there's no
    # single other row this could unambiguously override instead. Recorded on
    # the Approval too (same value, different column) so a dashboard can show
    # what was edited without reaching through the gate's own output.
    def approve!(by:, edited_payload: nil)
      gate = require_pending_gate!("approve")

      ActiveRecord::Base.transaction do
        approvals.create!(step: gate, status: "approved", decided_by: by, decided_at: Time.current,
                          edited_payload: edited_payload)
        gate.update!(status: "succeeded", output: edited_payload)
        resume!
      end

      ResumeRunJob.perform_later(id)
    rescue ActiveRecord::RecordNotUnique
      raise Error, "belay_runs##{id}'s gate :#{gate.name} was already decided by another approve!/reject! call"
    end

    # Rejects this run's pending gate: records a rejected Belay::Approval, settles
    # the gate step "failed" (there's no dedicated "rejected" Step status - a
    # rejected gate IS a failed step, the same terminal shape any other step's
    # unrecoverable failure takes), and fails the run outright. Unlike approve!,
    # nothing is enqueued: a rejection has no step to resume into, so there's
    # nothing for ResumeRunJob to do - re-entering the executor on a failed run
    # would just hit the gate's own "failed" row and raise (dispatch's
    # retry_or_raise, with max_attempts already exhausted), uncaught, inside a job
    # with no rescue. Failing the run directly, synchronously, avoids ever taking
    # that path.
    def reject!(by:)
      gate = require_pending_gate!("reject")

      reason = "gate :#{gate.name} rejected by #{by}"
      ActiveRecord::Base.transaction do
        approvals.create!(step: gate, status: "rejected", decided_by: by, decided_at: Time.current)
        gate.update!(status: "failed", error: { "reason" => reason })
        fail!(error: { "reason" => reason })
      end
    rescue ActiveRecord::RecordNotUnique
      raise Error, "belay_runs##{id}'s gate :#{gate.name} was already decided by another approve!/reject! call"
    end

    private

    # Shared by approve!/reject! - same "no pending gate" guard, worded for whichever
    # verb the caller used, so a human reading the raised error sees the action they
    # actually called, not a generic one.
    def require_pending_gate!(action)
      gate = pending_gate
      raise Error, "belay_runs##{id} has no pending gate to #{action}" if gate.nil?

      gate
    end

    # Each bang method declares its own required source status(es), rather than checking
    # a target-reachability graph: "running" is a legal target from both "pending" (start!)
    # and "paused" (resume!), and those two have different meanings that a graph keyed only
    # by target can't distinguish - it would let resume! fire on a never-started run.
    #
    # No concurrency guard: this reads status in memory, then does a plain update!. Two
    # processes racing on the same run (stale in-memory copies) can both pass the check.
    # Deferred to the leases work (Phase 1f) rather than solved here.
    def transition!(from:, to:, **attrs)
      allowed_from = Array(from)
      unless allowed_from.include?(status)
        raise InvalidTransitionError,
              "cannot transition belay_runs##{id} from #{status.inspect} to #{to.inspect} " \
              "(expected current status to be #{allowed_from.inspect})"
      end

      update!(**attrs, status: to)
    end
  end
end
