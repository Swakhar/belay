# frozen_string_literal: true

require "rails/engine"

module Belay
  # Makes Belay mountable in a host app: mount Belay::Engine => "/belay" in
  # config/routes.rb. isolate_namespace keeps every route helper, controller and
  # (once the dashboard views land) view path under the Belay:: namespace, so a
  # host app's own RunsController or route named "runs" never collides with this
  # gem's. isolate_namespace also gives the engine its own Zeitwerk autoloader for
  # app/controllers (and app/views, once those exist) - unlike every plain Ruby
  # class under lib/belay/ (Run, Step, Approval, ...), which is deliberately
  # require_relative'd from lib/belay.rb instead, with no Rails autoloading
  # convention to lean on (see those files' own comments on this). Controllers
  # are different: Rails engines are BUILT to autoload app/controllers this way,
  # so this is the one place in the gem that actually uses it, via the
  # conventional app/controllers + config/routes.rb directory layout at the gem
  # root (not under lib/ - belay.gemspec's spec.files lists app/**/* and
  # config/routes.rb alongside lib/**/* for exactly this).
  #
  # The engine's own config/routes.rb draws root to: "home#index" -
  # Belay::HomeController is a placeholder (app/controllers/belay/home_controller.rb)
  # that exists only to give THIS commit (mounting + authentication) something
  # real to route to and test end-to-end, before any dashboard page exists.
  # feat(dashboard): runs index..., the next commit, replaces it with "runs#index".
  class Engine < ::Rails::Engine
    isolate_namespace Belay
  end
end
