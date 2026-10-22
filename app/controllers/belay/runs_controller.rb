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

    private

    def filtered_runs
      runs = Run.order(created_at: :desc)
      runs = runs.where(status: params[:status]) if Run.statuses.key?(params[:status])
      runs = runs.where(workflow: params[:workflow]) if params[:workflow].present?
      runs
    end
  end
end
