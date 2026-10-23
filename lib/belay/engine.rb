# frozen_string_literal: true

require "rails/engine"

module Belay
  # Makes Belay mountable in a host app: mount Belay::Engine => "/belay" in
  # config/routes.rb. isolate_namespace keeps every route helper, controller and
  # view path under the Belay:: namespace, so a host app's own RunsController or
  # route named "runs" never collides with this gem's. isolate_namespace also
  # gives the engine its own Zeitwerk autoloader for app/controllers and
  # app/views - unlike every plain Ruby class under lib/belay/ (Run, Step,
  # Approval, ...), which is deliberately require_relative'd from lib/belay.rb
  # instead, with no Rails autoloading convention to lean on (see those files'
  # own comments on this). Controllers are different: Rails engines are BUILT to
  # autoload app/controllers this way, so this is the one place in the gem that
  # actually uses it, via the conventional app/controllers + app/views +
  # config/routes.rb directory layout at the gem root (not under lib/ -
  # belay.gemspec's spec.files lists app/**/* and config/routes.rb alongside
  # lib/**/* for exactly this).
  class Engine < ::Rails::Engine
    isolate_namespace Belay

    # The dashboard's CSS, inlined into the layout via <style> rather than
    # served through a <link> and whichever asset pipeline (Sprockets,
    # Propshaft, none at all) the host app happens to have configured - that's
    # exactly the kind of host-app assumption Belay has never made anywhere
    # else (no Zeitwerk assumption, explicit class_name: throughout, routes
    # drawn from the engine's own config/routes.rb). app/assets/belay/
    # application.css is a committed, precompiled Tailwind build (see
    # package.json's build:css) - there is no runtime build step, and this
    # gem's own end users never run npm.
    #
    # Memoized at the class level (not per-request, unlike an instance
    # variable in a helper) - the file never changes while the process is
    # running, so re-reading it on every single request would be pure waste.
    def self.stylesheet
      @stylesheet ||= root.join("app/assets/belay/application.css").read
    end
  end
end
