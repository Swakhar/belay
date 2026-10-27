# Dashboard

```ruby
# config/routes.rb
mount Belay::Engine => "/belay"

# config/initializers/belay.rb
Belay.configure do |config|
  config.authenticate_with = ->(request) { request.env["warden"]&.authenticate(:scope => :admin) }
end
```

`Belay::Engine` is a real, isolated `Rails::Engine` (`isolate_namespace Belay`, so its routes/controllers never collide with a host app's own).

## Authentication - bring your own

Belay has no identity or authorization system of its own. It doesn't bundle Devise, Pundit, CanCanCan, or anything else - `authenticate_with` is a plain `->(request) { true/false }` proc, wired into whatever the host app already uses:

```ruby
config.authenticate_with = ->(request) { request.env["warden"]&.user&.admin? }                      # Devise
config.authenticate_with = ->(request) { Ability.new(current_user(request)).can?(:manage, :belay_dashboard) } # CanCanCan
```

It answers only "is this request allowed at all" - never "who is asking." There's no default that lets anyone through: mounting the engine without configuring this raises a clear `Belay::Error` on the very first request, rather than quietly serving the dashboard (prompts, responses, costs, approve/reject actions) to the whole internet.

Because `authenticate_with` has no identity concept, Belay also has no way to record *who* approved something automatically - `approve!(by:, ...)` and friends take a plain string you supply yourself (an email, a username), not a user object.

## Pages

- **Runs** (root, `Belay::RunsController#index`) - every run, most recently created first, with `?status=`/`?workflow=` filters.
- **Run detail** (`#show`) - the full step timeline (every retry attempt, not just the latest), an `llm_call` step's prompt/response/model/tokens/cost, and forms for whichever of approve!/reject!/resolve_needs_review! applies.
- **Replay diff** (`#diff`) - a side-by-side table of `run.replay_diff`, one row per step, flagged changed/unchanged/not-reached.
- **Stats** (`Belay::StatsController#index`) - real provider calls (an `llm_call` step with `cache_hit: false`) per 100 runs, by day, so caching and rules' actual effect on cost is something you can look at rather than code with no visible effect.

## Styling

The dashboard is styled with Tailwind, compiled and vendored - `app/assets/belay/application.css` is a committed build, inlined into the layout via `Belay::Engine.stylesheet`, never served through whichever asset pipeline (Sprockets, Propshaft, none at all) the host app happens to have. There's no runtime build step and no npm dependency for anyone who installs this gem.

Contributing to the gem itself and changing a view's classes? `npm install && npm run build:css` regenerates it from `tailwind/application.css` - see `package.json`.

Every page shares one small design system: `Belay::ApplicationHelper#status_badge` groups statuses by what they *mean* (done-and-fine, stopped-and-waiting-on-a-human, done-and-not-fine, in-progress) rather than by literal value, and `tailwind/application.css`'s `@layer components` defines a fixed, small set of button/field/card classes every view reuses. See [DESIGN_DECISIONS.md #17](../DESIGN_DECISIONS.md) for why the CSS is vendored this way.
