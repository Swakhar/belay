# frozen_string_literal: true

module Belay
  class Run < ApplicationRecord
    self.table_name = "belay_runs"

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

    def complete!
      transition!(from: "running", to: "completed", finished_at: Time.current)
    end

    def fail!(error: nil)
      transition!(from: %w[pending running paused], to: "failed", finished_at: Time.current, error: error)
    end

    def cancel!
      transition!(from: %w[pending running paused], to: "cancelled", finished_at: Time.current)
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
