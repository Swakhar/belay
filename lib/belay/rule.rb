# frozen_string_literal: true

require "digest"

module Belay
  # A learned, auto-approvable gate occurrence - see belay_rules' own migration
  # comment for the identity/status columns. The only two write entry points are
  # .record_approval! and .record_rejection!, called from Run#approve!/reject!
  # below; nothing else ever changes a rule's status.
  class Rule < ApplicationRecord
    self.table_name = "belay_rules"

    enum :status, {
      learning: "learning",
      active: "active",
      invalidated: "invalidated"
    }

    validates :workflow, :workflow_version, :gate_name, :context_key, :status, presence: true

    # SHA256 of [input, outputs, a fingerprint of condition].inspect - the exact
    # input/outputs a gate's when: was evaluated against, AND which when: actually
    # evaluated them. Computed once, at evaluation time (Executor#evaluate_gate!),
    # from the live Context's own symbol-keyed Hashes - never re-derived later from
    # a round-tripped jsonb Hash (string-keyed), which would silently stop matching
    # anything. Same exact-match-hash approach as Belay::CacheEntry.key_for, same
    # reasoning: deliberately not normalized, and deliberately the FULL input/
    # outputs snapshot rather than just whatever a gate's own when: closure happens
    # to read - a narrower key could auto-settle a future occurrence that looks
    # identical to the closure but differs in some upstream value nobody declared
    # as relevant.
    #
    # condition is included because Workflow.workflow_version is NOT enough to
    # catch an edited when: on its own: workflow_version deliberately hashes only
    # [inputs, steps.map { [name, kind] }] - not step/gate options: (see its own
    # comment) - so rewriting a gate's when: entirely, while keeping its name and
    # the workflow's other steps unchanged, leaves workflow_version identical.
    # Without this, a rule learned under the OLD condition could auto-settle a
    # gate running the NEW one, for any (input, outputs) that happens to recur -
    # silently approving a decision whose logic no human ever actually reviewed.
    # condition.source_location (file + line) is used as that fingerprint rather
    # than condition.inspect - a Proc's default #inspect embeds its object_id
    # (the lambda's memory address), which changes across every process restart
    # even with zero code changes, which would make every rule stop matching
    # after every deploy. source_location only changes when the when: actually
    # moves or is rewritten - not a perfect signal (editing a single-line lambda's
    # body in place without changing which line it starts on isn't caught, and
    # neither is a parameterized factory reused as when: threshold_gate(100) ->
    # threshold_gate(200), since the lambda literal itself never moves), but it
    # closes the realistic case (any edit that adds/removes a line anywhere
    # above it in the file, or rewrites the condition across multiple lines)
    # without the deploy-time false-invalidation problem.
    # Falls back to the condition's class name for a when: that isn't a Proc/
    # Method (Workflow#gate only requires #call, via validate_gate_when!) and so
    # has no #source_location of its own.
    def self.context_key_for(input:, outputs:, condition:)
      fingerprint = condition.respond_to?(:source_location) ? condition.source_location : condition.class.name
      Digest::SHA256.hexdigest([input, outputs, fingerprint].inspect)
    end

    # Records one more consistent, unedited approve! of this exact gate
    # occurrence. A rule already invalidated never advances and never becomes
    # active again, regardless of how many further approvals arrive for the
    # same context - re-checked AFTER the counter update (not just before),
    # since a concurrent record_rejection! for this same row could invalidate
    # it in the gap between create_or_find_by! and increment! below. That's
    # the one invariant this method guarantees; the counter itself tolerates
    # a little noise (one increment landing on a row a racing reject! is about
    # to invalidate) because invalidation is permanent and always wins.
    def self.record_approval!(workflow:, workflow_version:, gate_name:, context_key:,
                              threshold: Belay.config.rule_approval_threshold)
      # create_or_find_by!, not find_or_create_by! - two different RUNS racing to be
      # the FIRST approval for an identical, not-yet-existing context_key is a real
      # scenario here (any two runs with identical input/outputs at this gate
      # collide by design), and find_or_create_by! isn't atomic against that: both
      # could find nothing and both call create!, and the loser would raise
      # ActiveRecord::RecordNotUnique uncaught. create_or_find_by! inserts first and
      # falls back to a find on exactly that violation. Same race CacheEntry.store!
      # (via upsert) and Workflow.find_or_create_run (via an explicit rescue) each
      # already guard against elsewhere in this codebase.
      rule = create_or_find_by!(workflow: workflow, workflow_version: workflow_version, gate_name: gate_name,
                                context_key: context_key)
      rule.increment!(:consistent_approvals) unless rule.invalidated?
      rule.reload
      rule.update!(status: "active") if rule.learning? && rule.consistent_approvals >= threshold
      rule
    end

    # Permanently invalidates the rule for this exact gate occurrence - a SINGLE
    # rejection is enough, with no tolerance for "mostly consistent," and once
    # invalidated a rule can never become active again (record_approval! above
    # refuses to advance an invalidated rule's counter). Creates the row even if
    # this is the very first decision ever made for this context, so a future
    # run of consistent approvals can never learn a rule here from scratch.
    def self.record_rejection!(workflow:, workflow_version:, gate_name:, context_key:)
      # create_or_find_by! - same race as record_approval! above, guarded the same way.
      rule = create_or_find_by!(workflow: workflow, workflow_version: workflow_version, gate_name: gate_name,
                                context_key: context_key)
      rule.update!(status: "invalidated", invalidated_at: Time.current)
      rule
    end

    # nil when there's no rule for this exact gate occurrence yet, or it's still
    # learning, or it's been invalidated - Executor#evaluate_gate! treats all
    # three the same way (pause for a human), so this collapses them into one
    # "nothing to auto-apply" answer rather than returning a status a caller
    # would have to branch on.
    def self.active_for(workflow:, workflow_version:, gate_name:, context_key:)
      find_by(workflow: workflow, workflow_version: workflow_version, gate_name: gate_name,
              context_key: context_key, status: "active")
    end
  end
end
