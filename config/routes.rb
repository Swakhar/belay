Belay::Engine.routes.draw do
  resources :runs, only: [:index, :show]
  root to: "runs#index"
end
