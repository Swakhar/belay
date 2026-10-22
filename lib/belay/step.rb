# frozen_string_literal: true

module Belay
  class Step < ApplicationRecord
    self.table_name = "belay_steps"

    # Explicit class_name: this gem has no Zeitwerk/app-autoloading, so association
    # class lookup can't rely on namespace inference the way it would inside a
    # conventionally-autoloaded Rails engine. Explicit optional: false too: Rails only
    # requires belongs_to associations by default when the host app's load_defaults is
    # 7.0+. A library shouldn't depend on that config to get a friendly validation error
    # instead of a raw DB NotNullViolation.
    belongs_to :run, class_name: "Belay::Run", optional: false

    # has_one, not has_many: belay_approvals.step_id is unique at the DB level -
    # at most one approval per gate step (see its migration's own comment on why,
    # and the forward constraint that assumes).
    has_one :approval, class_name: "Belay::Approval"

    enum :kind, {
      llm_call: "llm_call",
      tool_call: "tool_call",
      decision: "decision",
      gate: "gate"
    }

    enum :status, {
      started: "started",
      succeeded: "succeeded",
      failed: "failed",
      skipped: "skipped",
      needs_review: "needs_review"
    }

    validates :position, presence: true
    validates :name, presence: true
    validates :kind, presence: true
    validates :idempotency_key, presence: true

    # status has a DB default ("started"), but the enum writer accepts nil as a valid
    # "blank" assignment (no ArgumentError) - without this, an explicit status: nil
    # would skip the default and hit a raw NotNullViolation instead of RecordInvalid.
    validates :status, presence: true

    # No guarded transitions here, unlike Run: the executor (Phase 1e) owns the
    # started -> succeeded/failed/needs_review policy, including retry rules that
    # depend on an idempotent: declaration this model doesn't have. Adding bang
    # methods here now would mean rebuilding them once that policy exists.
  end
end
