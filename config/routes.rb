Belay::Engine.routes.draw do
  resources :runs, only: [:index, :show] do
    member do
      post :approve
      post :reject
      post :resolve
      get :diff
    end
  end
  root to: "runs#index"
end
