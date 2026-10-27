# frozen_string_literal: true

module Belay
  module ApplicationHelper
    # One canonical place deciding what a status looks like, rather than each
    # view picking its own color per status - a Run has six possible statuses,
    # a Step has six different ones, and they overlap in meaning (e.g. both
    # have a "failed") without sharing a Ruby class to hang a shared method on
    # (Run and Step are unrelated models) - a view helper is the natural shared
    # home instead.
    #
    # Semantic grouping, not one color per literal status value: "succeeded"
    # and "completed" both mean done-and-fine (emerald); "paused",
    # "awaiting_approval" and "needs_review" all mean stopped-and-waiting-on-a-
    # human (amber); "failed" and "cancelled" both mean done-and-not-fine
    # (rose); "running" and "started" both mean in-progress (sky); anything
    # else ("pending", "skipped") is neutral (slate).
    STATUS_COLORS = {
      "succeeded" => :emerald,
      "completed" => :emerald,
      "paused" => :amber,
      "awaiting_approval" => :amber,
      "needs_review" => :amber,
      "failed" => :rose,
      "cancelled" => :rose,
      "running" => :sky,
      "started" => :sky
    }.freeze

    # Tinted-on-dark, not the light "-100 bg / -800 text" pairing a white page
    # would use (Phase 5's dark-mode redesign) - a translucent background at
    # the same lightness step as the text color keeps each badge legible
    # against the dark card surface it sits on, rather than becoming a solid
    # light rectangle that'd clash with everything around it.
    BADGE_CLASSES = {
      emerald: "bg-emerald-500/10 text-emerald-400",
      amber: "bg-amber-500/10 text-amber-400",
      rose: "bg-rose-500/10 text-rose-400",
      sky: "bg-sky-500/10 text-sky-400",
      slate: "bg-slate-500/10 text-slate-400"
    }.freeze

    def status_badge(status)
      color = STATUS_COLORS.fetch(status, :slate)
      content_tag(:span, status, class: "status-badge inline-flex items-center rounded-full px-2.5 py-0.5 " \
                                        "text-xs font-medium #{BADGE_CLASSES.fetch(color)}")
    end

    # The runs index hands its own current path (filters and all) to each run
    # link as return_to:, so a run's "back to runs" link restores the exact
    # filtered list a human came from, not always the unfiltered one.
    # return_to: is otherwise untrusted query input - anyone can hand-edit a
    # URL - so only a value that's actually runs_path itself, or runs_path
    # with a query string, is honored; anything else (an absolute URL to
    # another host, a lookalike path) falls back to the plain runs index
    # instead of becoming an open redirect a human could be tricked into
    # clicking.
    def back_to_runs_path(request)
      candidate = request.params[:return_to]
      base = runs_path
      return base unless candidate.is_a?(String) && (candidate == base || candidate.start_with?("#{base}?"))

      candidate
    end
  end
end
