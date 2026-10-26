Belay::Engine.routes.draw do
  resources :runs, only: [:index, :show] do
    member do
      post :approve
      post :reject
      post :resolve
      get :diff
    end
  end
  get "stats", to: "stats#index"

  root to: "runs#index"
end
