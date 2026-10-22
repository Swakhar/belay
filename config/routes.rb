Belay::Engine.routes.draw do
  resources :runs, only: [:index]
  root to: "runs#index"
end
