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

    BADGE_CLASSES = {
      emerald: "bg-emerald-100 text-emerald-800",
      amber: "bg-amber-100 text-amber-800",
      rose: "bg-rose-100 text-rose-800",
      sky: "bg-sky-100 text-sky-800",
      slate: "bg-slate-100 text-slate-700"
    }.freeze

    def status_badge(status)
      color = STATUS_COLORS.fetch(status, :slate)
      content_tag(:span, status, class: "status-badge inline-flex items-center rounded-full px-2.5 py-0.5 " \
                                        "text-xs font-medium #{BADGE_CLASSES.fetch(color)}")
    end
  end
end
