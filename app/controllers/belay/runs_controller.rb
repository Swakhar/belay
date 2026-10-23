# frozen_string_literal: true

module Belay
  class RunsController < ApplicationController
    # status: is untrusted query input (anyone who passes authenticate_belay!
    # can still type anything into the URL). where(status: ...) on an
    # unrecognized value doesn't actually raise - unlike direct assignment
    # (run.status = "bogus", which DOES raise ArgumentError), a where clause
    # just matches zero rows, the same as any other string column. Checked
    # against Run.statuses (the enum's own declared mapping) anyway, as a UX
    # choice, not a crash guard: a mistyped or hand-edited ?status= should
    # show every run rather than silently show none.
    #
    # workflow: needs no such check - it's a plain string column, not an enum,
    # so an unrecognized value just matches zero rows via an ordinary
    # parameterized WHERE, the same as it would for a typo'd value on any
    # other plain column.
    def index
      @runs = filtered_runs
      @statuses = Run.statuses.keys
      @workflows = Run.distinct.order(:workflow).pluck(:workflow)
    end

    # Run.find, not a rescued custom lookup: ActiveRecord::RecordNotFound is
    # already in Rails' own default list of exceptions rendered as a plain 404,
    # unlike a bespoke Belay::Error (see ApplicationController's own comment on
    # authenticate_belay! raising loudly on purpose) - a run id that doesn't
    # exist is an ordinary, expected "nothing there" case, not a misconfiguration
    # worth failing loudly over.
    #
    # Every attempt of every step, not just the latest: a "timeline" is a record
    # of what happened, including retries, same reasoning DESIGN_DECISIONS #7
    # ("gates are steps") gives for checkpointing every outcome rather than only
    # the final one.
    def show
      @run = Run.find(params[:id])
      @steps = @run.steps.order(:position, :attempt)
    end

    # by: is a plain form field, not derived from the authenticated request -
    # authenticate_with only ever answers "is this request allowed," not "who
    # is making it" (see ApplicationController's own comment on that), so this
    # gem has no identity concept of its own to read an actor from. Required
    # non-blank here, not at the model/migration level (Run#approve!/reject!
    # and the belay_approvals.decided_by column both happily accept nil) - a
    # recorded decision with no actor defeats the point of the audit trail
    # this dashboard exists to show, but that's a dashboard-level policy
    # choice, not something every caller of approve!/reject! should be forced
    # into (a script calling them directly might reasonably use a fixed
    # system identity instead).
    def approve
      @run = Run.find(params[:id])
      return redirect_with(alert: "who is approving this?") if params[:by].blank?

      @run.approve!(by: params[:by], edited_payload: parsed_edited_payload)
      redirect_with(notice: "Approved.")
    rescue Error => e
      redirect_with(alert: e.message)
    rescue JSON::ParserError
      redirect_with(alert: "edited payload must be valid JSON")
    end

    def reject
      @run = Run.find(params[:id])
      return redirect_with(alert: "who is rejecting this?") if params[:by].blank?

      @run.reject!(by: params[:by])
      redirect_with(notice: "Rejected.")
    rescue Error => e
      redirect_with(alert: e.message)
    end

    # outcome: is form input (two separate forms on the run page, one per
    # outcome, each with a hidden field set to its own value), checked against
    # Run::RESOLUTIONS the same way approve/reject check for a pending gate
    # first - resolve_needs_review! itself also raises ArgumentError for an
    # unrecognized outcome, but checking it here first keeps that message a
    # flash alert instead of a raw 500 for a tampered/malformed request.
    def resolve # rubocop:disable Metrics/AbcSize
      @run = Run.find(params[:id])
      invalid = invalid_resolve_params
      return redirect_with(alert: invalid) if invalid

      @run.resolve_needs_review!(by: params[:by], outcome: params[:outcome], output: parsed_output)
      redirect_with(notice: "Resolved as #{params[:outcome]}.")
    rescue Error => e
      redirect_with(alert: e.message)
    rescue JSON::ParserError
      redirect_with(alert: "output must be valid JSON")
    end

    private

    def invalid_resolve_params
      return "who is resolving this?" if params[:by].blank?
      return "outcome must be succeeded or failed" unless Run::RESOLUTIONS.include?(params[:outcome])

      nil
    end

    def redirect_with(notice: nil, alert: nil)
      redirect_to run_path(@run), notice: notice, alert: alert
    end

    # nil (not {}) when the field was left blank - approve!'s own edited_payload:
    # nil default means "nothing edited," distinct from an explicitly-submitted
    # empty object.
    def parsed_edited_payload
      raw = params[:edited_payload].presence
      raw && JSON.parse(raw)
    end

    # Only parsed for outcome: "succeeded" - resolve_failed! ignores output:
    # entirely, so a stray/malformed output: on an outcome: "failed" request
    # shouldn't reject it over something that was never going to be used.
    def parsed_output
      return nil unless params[:outcome] == "succeeded"

      raw = params[:output].presence
      raw && JSON.parse(raw)
    end

    def filtered_runs
      runs = Run.order(created_at: :desc)
      runs = runs.where(status: params[:status]) if Run.statuses.key?(params[:status])
      runs = runs.where(workflow: params[:workflow]) if params[:workflow].present?
      runs
    end
  end
end
