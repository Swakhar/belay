Belay::Engine.routes.draw do
  resources :runs, only: [:index, :show] do
    member do
      post :approve
      post :reject
      post :resolve
    end
  end
  root to: "runs#index"
end
