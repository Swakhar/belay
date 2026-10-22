# frozen_string_literal: true

module Belay
  # Base controller for everything Belay::Engine mounts. The only thing it does
  # today is gate every request behind Belay.config.authenticate_with - no
  # dashboard controller exists yet (that's the next several commits), but
  # whichever ones land will inherit this and get the same gate for free, rather
  # than each wiring its own before_action.
  class ApplicationController < ActionController::Base
    before_action :authenticate_belay!

    private

    # authenticate_with defaulting to nil means "not configured yet," not
    # "allow everyone" - the dashboard shows prompts, responses, costs and
    # approve/reject actions, so serving it to an unauthenticated request by
    # default would be the wrong failure mode for something this sensitive.
    # Raising here is loud and immediate (the same "fail clearly, don't guess"
    # choice ctx.llm makes for a missing provider:, see lib/belay/context.rb) -
    # a host app that mounts the engine and forgets to configure this finds out
    # on its very first request, not by discovering the dashboard was open the
    # whole time.
    #
    # Once configured, the proc is called with the real ActionDispatch::Request
    # (not this controller) - it only needs to answer "is this request allowed,"
    # not act on the response; it returns truthy to allow, anything else denies
    # with a plain 401.
    def authenticate_belay!
      authenticator = Belay.config.authenticate_with
      if authenticator.nil?
        raise Error, "Belay::Engine is mounted but Belay.config.authenticate_with isn't set - configure one, " \
                     "e.g. Belay.configure { |c| c.authenticate_with = ->(request) { ... } }, before anyone " \
                     "can reach this dashboard"
      end

      head :unauthorized unless authenticator.call(request)
    end
  end
end
