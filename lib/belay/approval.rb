# frozen_string_literal: true

module Belay
  class Approval < ApplicationRecord
    self.table_name = "belay_approvals"

    # Explicit class_name and optional: false for the same reason Step declares
    # them this way: no Zeitwerk/app-autoloading here to infer the namespace from,
    # and optional: false stated explicitly doesn't depend on the host app's
    # load_defaults to get a friendly validation error instead of a raw DB
    # NotNullViolation.
    belongs_to :run, class_name: "Belay::Run", optional: false
    belongs_to :step, class_name: "Belay::Step", optional: false

    enum :status, {
      pending: "pending",
      approved: "approved",
      rejected: "rejected"
    }

    # status has a DB default ("pending"), but the enum writer accepts nil as a
    # valid "blank" assignment (no ArgumentError) - without this, an explicit
    # status: nil would skip the default and hit a raw NotNullViolation instead of
    # RecordInvalid. Matches Step's own comment on the identical situation.
    validates :status, presence: true

    # No approve!/reject! here. Those are Run methods (feat(runs): add approve! and
    # reject! that enqueue ResumeRunJob, not this commit) - a decision resolves the
    # RUN's pending gate, not just this row in isolation, the same reason
    # transitions live on Run rather than Step: Belay::Run#start!/pause!/etc. own
    # the run-level policy, and Step has no bang methods of its own either (see its
    # comment on exactly this). Adding them here now would mean rebuilding them
    # once that policy exists, same as Step's own stated reasoning.
  end
end
