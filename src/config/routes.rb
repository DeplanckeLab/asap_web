Rails.application.routes.draw do
  devise_for :users
  resources :projects do
    resources :checkpoints, only: [:index, :create, :show, :update, :destroy] do
      collection do
        get :current
        put :current, action: :upsert_current
        delete :current, action: :destroy_current
      end
    end
    collection do
      get :organisms_for_version
      post :bulk_destroy
      post :prepare_integrate
      get :run_counts_batch
      get :search_snapshot
    end
    member do
      get :instructions
      get :get_commands
      get :get_file
      get :get_loom_files_json
      post :export_h5ad
      get :data_file_metadata_catalog
      get :project_data_files
      get :get_step
      get :get_run
      get :get_lineage
      get :summary_test
      get :tsv_from_json
      get :metadata_coordinates
      get :spatial_data
      get :spatial_image
      get :metadata_vectors
      get :gene_expression
      get :heatmap_data
      get :heatmap_metadata_catalog
      get :heatmap_track
      get :get_autocomplete_genes
      get :creating
      get :creation_status
      get :step_results
      get :refresh_steps_panel
      get :queue_position
      get :get_attributes
      post :upd_pred
      get :data_content
      post :restart_step
      post :stop_parsing
      post :delete_all_runs_from_step
      get :reset_parsing
      get :run_status
      get :run_counts
      get :run_list
      get :unarchive_status
      get :clone_status
      get :graph
      get :pipeline_runs
      get :search_gene
      get :search_gene_memberships
      get :search_gene_membership_items
      post :search_gene_set_overlaps
      get :search_gene_set_items
      get :gene_set_collection_items
      get :gene_set_collection_status
      get :gene_set_item_genes
      get :gene_set_item_module_score
      post :cancel_gene_set_item_module_score
      get :download_gene_set_collection
      post :save_manual_gene_set
      post :create_gene_set_collection
      post :save_de_gene_set
      post :import_gene_set_collection
      post :delete_manual_gene_set
      post :cluster_comparison
      post :filter_de_results
      get  :viz_de_results
      post :viz_de_results
      post :filter_ge_results
      post :filter_doublet_results
      get :get_annot_info
      post :create_cla
      get :get_annot_evidences
      get :search_visualization_metadata
      get :get_cell_set_annotations
      get :discover_metadata_import_sources
      get :discover_metadata_import_from_project
      get :metadata_import_cell_sets
      post :prepare_metadata_from_project_annot
      post :clone
      post :toggle_public
      post :transfer_ownership
      post :prepare_metadata
      post :do_import_metadata
      post :export_consensus_annotation
      post :preview_consensus_annotation
      get :related_clone_projects
      get :federated_annotations
      get :consensus_annotation_support
      post :save_metadata_from_selection
      post :save_batch_compose_metadata
      post :stage_de_cell_universe
      post :delete_selection
      post :rename_selection
      post :rename_gene_set_collection
      post :delete_gene_set_collection
      get :collection_owned_project_autocomplete
      post :collection_add_project
      get :selection_states
      get :sample_identifiers
      get :project_data_files
      get :data_file_metadata_catalog
      get :fix_compliance, to: 'compliance#fix_project'
      post :apply_compliance_fix, to: 'compliance#apply_project_fix'
      get :compliance_metadata_fields, to: 'compliance#project_metadata_fields'
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
  
  resources :annots, only: [:show, :edit, :update] do
    member do
      get :download
      get :categories
    end
  end
  resources :runs do
    member do
      get :get_de_gene_list
      get :get_ge_geneset_list
      post :restart
      post :stop
      post :report_error
    end
  end
  resources :reqs
  resources :docker_images
  resources :docker_builds, only: [:index]
  resources :tools
  resources :ratings, only: [:index]
  resources :storage_usages, only: [:index]
  resources :standalone_compliance_checks, only: [:index, :show]
  resources :external_catalog_candidates, only: [:index, :show, :destroy] do
    member do
      post :create_project
      get :import_status
    end
  end
  resources :data_classes
  resources :tool_types
  resources :project_types
  resources :ontology_term_types
  resources :cell_ontologies
  resources :steps do
    patch :reorder, on: :collection
  end
  resources :std_methods do
    patch :index_filters, on: :collection
  end
  resources :statuses
  resources :guided_tours do
    get :editor, on: :collection
    patch :reorder, on: :collection
    patch :reorder_steps, on: :member, to: 'guided_tour_steps#reorder'
    resources :guided_tour_steps, path: :steps, only: [:create, :update, :destroy]
  end
  
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

  resources :news_items do
    member do
      post :sync_to_github
    end
  end
  
  resources :home do
    collection do
      get :home
      get :guided_tours
      get :tutorial
      get :file_format
      get :cross_references
      get :cross_references_admin
      get :faq
      get :citing
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
      # Legacy URLs (prefer /projects/:key/fix_compliance and related member routes)
      get 'fix', to: redirect { |path_params, _req| "/projects/#{path_params[:id]}/fix_compliance" }
      post 'apply_fix', action: :apply_project_fix, as: :compliance_project_apply_fix
      get 'metadata_fields', to: redirect { |path_params, _req| "/projects/#{path_params[:id]}/compliance_metadata_fields" }
    end
    get 'ontology_autocomplete', action: :ontology_autocomplete, as: :compliance_ontology_autocomplete
    post 'resolve_ontology_terms', action: :resolve_ontology_terms, as: :compliance_resolve_ontology_terms
  end

  get '/compliance/file-check', to: 'compliance_file_checks#index', as: :compliance_file_check
  post '/compliance/file-check', to: 'compliance_file_checks#create', as: :compliance_file_check_create
  get '/compliance/file-check/:task_id/status', to: 'compliance_file_checks#status', as: :compliance_file_check_status
  get '/compliance/rules_snippet', to: 'compliance_file_checks#rules_snippet', as: :compliance_rules_snippet
  get '/compliance/rules_yaml', to: 'compliance_file_checks#rules_yaml', as: :compliance_rules_yaml
  get '/compliance/checks', to: 'compliance_file_checks#lookup', as: :compliance_checks_lookup, defaults: { format: :json }
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  mount ActionCable.server => ENV.fetch('ACTION_CABLE_MOUNT_PATH', '/websocket')
  
  # Defines the root path route ("/")
  # root "posts#index"

  get '/unauthorized', to: 'home#unauthorized', as: :unauthorized
  get '/orcid_authentication', to: 'home#orcid_authentication', as: :orcid_authentication
  get '/associate_orcid', to: 'home#associate_orcid', as: :associate_orcid
  get '/atlases', to: 'home#atlases', as: :atlases
  get '/atlases/:atlas', to: 'home#atlas_projects', as: :atlas_projects
  namespace :api, defaults: { format: :json } do
    get 'projects', to: '/projects#index'
    get 'projects/:id', to: '/projects#show'
    get 'projects/:id/project_data_files', to: '/projects#project_data_files'
    get 'projects/:id/data_file_metadata_catalog', to: '/projects#data_file_metadata_catalog'
    get 'compliance/checks', to: '/compliance_file_checks#lookup'
    resources :guided_tours, only: %i[index show]
    get 'openapi.yaml', to: '/home#openapi_spec', defaults: { format: nil }
  end
  get '/api-doc', to: 'home#api_documentation', as: :api_doc
  get '/api-doc/index.html', to: redirect('/api-doc', status: 302)
  get '/guided-tours', to: 'home#guided_tours', as: :public_guided_tours
  get '/sitemap.xml', to: 'home#sitemap', as: :sitemap
  get '/robots.txt', to: 'home#robots', as: :robots
  get '/llms.txt', to: 'home#llms', as: :llms
  post '/security/session_cookie_challenge/solve', to: 'security#solve_session_cookie_challenge'
  root "home#welcome"

end
