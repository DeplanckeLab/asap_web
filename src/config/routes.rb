Rails.application.routes.draw do
  devise_for :users
  resources :projects do
    collection do
      get :organisms_for_version
      post :bulk_destroy
      post :prepare_integrate
    end
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
      get :metadata_coordinates
      get :metadata_vectors
      get :gene_expression
      get :creating
      get :creation_status
      get :step_results
      get :refresh_steps_panel
      get :queue_position
      get :get_attributes
      get :data_content
      post :restart_step
      post :delete_all_runs_from_step
      get :reset_parsing
      get :run_status
      get :run_counts
      get :graph
      get :pipeline_runs
      get :search_gene
      get :search_gene_set_items
      post :cluster_comparison
      post :filter_de_results
      post :filter_ge_results
      post :clone
      post :toggle_public
    end
  end
  
  resources :fus do
    collection do
      post :upload_chunk
      get :upload_status
      post :download_from_url
    end
    member do
      post :rerun_preparsing
      get :preparsing_status
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
  
  resources :annots, only: [:show]
  resources :runs do
    member do
      get :get_de_gene_list
      get :get_ge_geneset_list
    end
  end
  resources :reqs
  resources :docker_images
  resources :tools
  resources :data_classes
  resources :tool_types
  resources :project_types
  resources :ontology_term_types
  resources :cell_ontologies
  resources :steps
  resources :std_methods
  resources :statuses
  
  resources :shares, only: [:create, :update, :destroy] do
    collection do
      post :batch_add
    end
  end
  
  resources :compliance_schemas, except: [:destroy]

  resources :versions do
    collection do
      get :last_version
    end
    member do
      get :run_stats
    end
  end
  
  resources :home do
    collection do
      get :home
      get :tutorial
      get :file_format
      get :cross_references
      get :cross_references_admin
      get :faq
      get :contact
      post :contact_submit
      get :rate
      post :rate_submit
    end
  end

  resources :identifier_types, only: :show

  resources :organisms, only: :index

  # CXG Schema Compliance routes
  scope '/compliance', controller: :compliance do
    get '/', action: :index, as: :compliance_index
    get 'schema/:version', action: :schema_docs, as: :compliance_schema_docs, constraints: { version: /[^\/]+/ }
    post 'validate', action: :validate, as: :compliance_validate
    post 'validate_file', action: :validate_file, as: :compliance_validate_file
    
    # Project-specific compliance routes
    scope '/projects/:id' do
      post 'validate', action: :validate_project, as: :compliance_project_validate
      get 'result', action: :show_project_result, as: :compliance_project_result
      get 'status', action: :project_status, as: :compliance_project_status
      get 'fix', action: :fix_project, as: :compliance_project_fix
      post 'apply_fix', action: :apply_project_fix, as: :compliance_project_apply_fix
      get 'metadata_fields', action: :project_metadata_fields, as: :compliance_project_metadata_fields
    end
    get 'ontology_autocomplete', action: :ontology_autocomplete, as: :compliance_ontology_autocomplete
    post 'resolve_ontology_terms', action: :resolve_ontology_terms, as: :compliance_resolve_ontology_terms
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  mount ActionCable.server => '/websocket'
  
  # Defines the root path route ("/")
  # root "posts#index"

  root "home#welcome"

end
