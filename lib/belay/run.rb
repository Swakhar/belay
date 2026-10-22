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

    private

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
