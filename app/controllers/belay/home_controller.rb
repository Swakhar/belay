# frozen_string_literal: true

module Belay
  # Temporary: the engine needs a real root route to prove mounting +
  # authentication actually work end-to-end (not just "designed") before any
  # real dashboard page exists. feat(dashboard): runs index with status and
  # workflow filters, the next commit, deletes this file and points Engine's
  # root at RunsController#index instead.
  class HomeController < ApplicationController
    def index
      head :ok
    end
  end
end
