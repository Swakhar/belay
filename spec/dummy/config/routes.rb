Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Mirrors exactly what the README tells a host app to do - this dummy app IS
  # the host app for spec/belay/engine_spec.rb's real HTTP-level tests.
  mount Belay::Engine => "/belay"

  # Defines the root path route ("/")
  # root "posts#index"
end
