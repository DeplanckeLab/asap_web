Rails.application.routes.draw do
  devise_for :users
  resources :projects do
    member do
      get :instructions
      get :get_commands
      get :get_file
      get :get_loom_files_json
      get :get_step
      get :get_run
      get :get_lineage
      get :summary_test
      get :tsv_from_json
    end
  end
  
  resources :articles do
    member do
      get :summary
    end
  end
  
  resources :exp_entries do
    member do
      get :summary
    end
  end
  
  resources :runs
  resources :reqs
  
  resources :home do
    collection do
      get :home
      get :tutorial
      get :file_format
    end
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  #  mount ActionCable.server => '/websocket'
#  mount SolidCable.server => '/websocket'
  
  # Defines the root path route ("/")
  # root "posts#index"

  root "home#welcome"

end
