Belay::Engine.routes.draw do
  resources :runs, only: [:index, :show] do
    member do
      post :approve
      post :reject
    end
  end
  root to: "runs#index"
end
