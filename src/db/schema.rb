# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_29_100000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "active_runs", id: :serial, force: :cascade do |t|
    t.boolean "async", default: true
    t.text "attrs_json", default: "{}"
    t.text "children_run_ids", default: ""
    t.text "command_json"
    t.datetime "created_at", precision: nil
    t.float "duration"
    t.text "error"
    t.text "lineage_run_ids"
    t.float "max_ram"
    t.integer "nber_cores"
    t.integer "num"
    t.text "output_json", default: "{}"
    t.integer "pid"
    t.text "pipeline_parent_run_ids", default: ""
    t.integer "pred_max_ram"
    t.integer "pred_process_duration"
    t.float "process_duration"
    t.integer "process_idle_duration"
    t.integer "project_id"
    t.integer "req_id"
    t.boolean "return_stdout", default: false
    t.text "run_children_json"
    t.integer "run_id"
    t.text "run_parents_json"
    t.datetime "start_time", precision: nil
    t.integer "status_id"
    t.integer "std_method_id"
    t.integer "step_id"
    t.datetime "submitted_at", precision: nil
    t.integer "user_id"
    t.float "waiting_duration"
  end

  create_table "annot_cell_sets", id: :serial, force: :cascade do |t|
    t.integer "annot_id"
    t.integer "cat_idx"
    t.integer "cell_set_id"
    t.datetime "created_at", precision: nil
    t.integer "project_id"
    t.datetime "updated_at", precision: nil
    t.index ["annot_id"], name: "idx_annot_cell_sets_annot_id"
    t.index ["cell_set_id"], name: "cell_set_id_annot_cell_sets"
  end

  create_table "annots", id: :serial, force: :cascade do |t|
    t.text "attr_name"
    t.integer "attr_output_id"
    t.text "attrs_json"
    t.text "cat_aliases_json"
    t.text "cat_info_json"
    t.text "categories_json"
    t.datetime "created_at", precision: nil
    t.text "data_class_ids"
    t.integer "data_transformation_id"
    t.integer "data_type_id"
    t.integer "dim", limit: 2
    t.text "filepath"
    t.text "headers_json"
    t.boolean "imported", default: false
    t.text "label"
    t.boolean "latest_version", default: true
    t.text "list_cat_json"
    t.float "max_val"
    t.float "mean_val"
    t.float "median_val"
    t.bigint "mem_size"
    t.float "min_val"
    t.text "name"
    t.integer "nb_na"
    t.integer "nb_zero"
    t.integer "nber_cats"
    t.integer "nber_cols"
    t.integer "nber_rows"
    t.integer "ori_run_id"
    t.integer "ori_step_id"
    t.integer "output_attr_id"
    t.integer "project_id"
    t.integer "run_id"
    t.integer "sim_step_id"
    t.integer "step_id"
    t.integer "store_run_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.integer "version_nber", default: 1
    t.index ["data_transformation_id"], name: "index_annots_on_data_transformation_id"
    t.index ["project_id", "name"], name: "idx_annots_project_name"
    t.index ["project_id", "store_run_id", "filepath", "name"], name: "idx_annots_finish_run_lookup"
  end

  create_table "archive_statuses", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "icon_class"
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "articles", id: :serial, force: :cascade do |t|
    t.text "abstract"
    t.text "authors"
    t.text "authors_json"
    t.datetime "created_at", precision: nil
    t.text "doi"
    t.text "first_author"
    t.text "issue"
    t.integer "journal_id"
    t.integer "pmid"
    t.datetime "published_at", precision: nil
    t.text "title"
    t.datetime "updated_at", precision: nil
    t.text "volume"
    t.integer "year"
  end

  create_table "articles_projects", id: false, force: :cascade do |t|
    t.integer "article_id"
    t.integer "project_id"
  end

  create_table "attr_outputs", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "cell_filterings", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "job_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "cell_ontologies", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "file_url"
    t.text "file_url_bkp"
    t.text "format"
    t.text "latest_version"
    t.text "name"
    t.boolean "obsolete", default: false
    t.text "tag"
    t.text "tax_ids"
    t.datetime "updated_at", precision: nil
    t.text "url"
    t.text "url_mask"
  end

  create_table "cell_ontologies_organisms", id: false, force: :cascade do |t|
    t.integer "cell_ontology_id"
    t.integer "organism_id"
  end

  create_table "cell_ontology_terms", id: :serial, force: :cascade do |t|
    t.text "alt_identifiers"
    t.integer "cell_ontology_id"
    t.text "children_term_ids"
    t.text "comment"
    t.text "content_json"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "identifier"
    t.text "latest_version"
    t.text "lineage"
    t.text "lineage_cot_ids"
    t.text "name"
    t.text "node_gene_ids"
    t.text "node_term_ids"
    t.boolean "obsolete", default: false
    t.boolean "original", default: false
    t.text "parent_term_ids"
    t.text "related_gene_ids"
    t.text "related_term_ids"
    t.integer "tax_id"
    t.datetime "updated_at", precision: nil
    t.index ["original", "identifier"], name: "idx_cot_original_identifier"
    t.index ["original", "name"], name: "idx_cot_original_name"
  end

  create_table "cell_sets", id: :serial, force: :cascade do |t|
    t.integer "cla_id"
    t.datetime "created_at", precision: nil
    t.text "key"
    t.integer "nber_cells"
    t.integer "nber_clas"
    t.integer "project_cell_set_id"
    t.datetime "updated_at", precision: nil
    t.index ["project_cell_set_id", "key"], name: "project_cell_set_id_key_cell_sets"
  end

  create_table "checkpoints", force: :cascade do |t|
    t.text "comments_json", default: "[]", null: false
    t.datetime "created_at", null: false
    t.boolean "is_landing_page", default: false, null: false
    t.integer "project_id", null: false
    t.text "state_json", default: "{}", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["project_id"], name: "index_checkpoints_on_project_id"
    t.index ["project_id"], name: "index_checkpoints_one_landing_page_per_project", unique: true, where: "(is_landing_page = true)"
    t.index ["user_id"], name: "index_checkpoints_on_user_id"
  end

  create_table "cla_sources", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "label"
    t.text "name"
    t.datetime "updated_at", precision: nil
    t.text "url"
  end

  create_table "cla_votes", id: :serial, force: :cascade do |t|
    t.boolean "agree"
    t.integer "cla_id"
    t.integer "cla_source_id"
    t.text "comment"
    t.datetime "created_at", precision: nil
    t.integer "orcid_user_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.text "user_name"
    t.text "voter_key"
  end

  create_table "clas", id: :serial, force: :cascade do |t|
    t.integer "annot_id"
    t.text "cat"
    t.integer "cat_idx"
    t.text "cell_ontology_term_ids"
    t.integer "cell_set_id"
    t.integer "cla_source_id"
    t.integer "clone_id"
    t.text "comment"
    t.datetime "created_at", precision: nil
    t.text "down_gene_ids"
    t.text "name"
    t.integer "nber_agree", default: 0
    t.integer "nber_disagree", default: 0
    t.integer "num"
    t.boolean "obsolete", default: false
    t.integer "ontology_term_type_id"
    t.integer "orcid_user_id"
    t.integer "project_id"
    t.text "sorted_cell_ontology_term_ids"
    t.text "sorted_down_gene_ids"
    t.text "sorted_up_gene_ids"
    t.text "up_gene_ids"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.index ["annot_id"], name: "idx_clas_annot_id"
    t.index ["ontology_term_type_id"], name: "index_clas_on_ontology_term_type_id"
  end

  create_table "cluster_methods", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "label"
    t.text "link"
    t.text "name"
    t.text "program"
    t.integer "speed_id", limit: 2
    t.datetime "updated_at", precision: nil
    t.text "warning"
  end

  create_table "clusters", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.integer "cluster_method_id"
    t.datetime "created_at", precision: nil
    t.integer "dim_reduction_id"
    t.integer "duration"
    t.text "error"
    t.integer "job_id"
    t.text "label"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "step_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
  end

  create_table "compliance_mappings", force: :cascade do |t|
    t.string "action_type", null: false
    t.datetime "applied_at", null: false
    t.integer "compliance_schema_id"
    t.datetime "created_at", null: false
    t.string "field_group_id", null: false
    t.integer "ontology_term_type_id"
    t.integer "project_id", null: false
    t.text "resolve_map_json"
    t.string "set_value"
    t.integer "source_annot_id"
    t.string "source_path"
    t.string "target_path", null: false
    t.datetime "updated_at", null: false
    t.index ["compliance_schema_id"], name: "index_compliance_mappings_on_compliance_schema_id"
    t.index ["ontology_term_type_id"], name: "index_compliance_mappings_on_ontology_term_type_id"
    t.index ["project_id", "field_group_id"], name: "index_compliance_mappings_on_project_id_and_field_group_id"
  end

  create_table "compliance_schemas", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "compliant_icon"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "ended_at"
    t.string "if_compliant"
    t.string "name", null: false
    t.string "not_compliant_icon"
    t.string "project_type_tags", null: false
    t.string "source_schema_name"
    t.string "source_url"
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.string "url"
    t.string "version"
    t.index ["active"], name: "index_compliance_schemas_on_active"
  end

  create_table "compliance_term_replacements", force: :cascade do |t|
    t.integer "cell_ontology_term_id"
    t.bigint "compliance_mapping_id", null: false
    t.datetime "created_at", null: false
    t.string "original_value", null: false
    t.string "replacement_identifier"
    t.string "replacement_name"
    t.datetime "updated_at", null: false
    t.index ["compliance_mapping_id"], name: "index_compliance_term_replacements_on_compliance_mapping_id"
    t.index ["original_value"], name: "index_compliance_term_replacements_on_original_value"
  end

  create_table "compliance_validations", force: :cascade do |t|
    t.integer "compliance_schema_id"
    t.datetime "created_at", null: false
    t.integer "errors_count", default: 0, null: false
    t.boolean "passed", default: false, null: false
    t.integer "project_id", null: false
    t.string "result_digest", limit: 32
    t.datetime "updated_at", null: false
    t.integer "valid_checks_count", default: 0, null: false
    t.datetime "validated_at", null: false
    t.integer "warnings_count", default: 0, null: false
    t.index ["compliance_schema_id"], name: "index_compliance_validations_on_compliance_schema_id"
    t.index ["project_id", "validated_at"], name: "index_compliance_validations_on_project_id_and_validated_at"
    t.index ["project_id"], name: "index_compliance_validations_on_project_id"
  end

  create_table "correlations", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "job_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "covariates", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "job_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "data_classes", id: :serial, force: :cascade do |t|
    t.string "category"
    t.datetime "created_at", precision: nil
    t.string "label_template"
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "data_repos", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "data_transformations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "label", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "data_types", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "label"
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "db_sets", id: :serial, force: :cascade do |t|
    t.text "label"
    t.text "tag"
    t.integer "tool_id"
  end

  create_table "del_runs", id: :serial, force: :cascade do |t|
    t.boolean "async", default: true
    t.text "attrs_json", default: "{}"
    t.text "children_run_ids", default: ""
    t.integer "cloned_run_id"
    t.text "command_json"
    t.datetime "created_at", precision: nil
    t.float "duration"
    t.text "error"
    t.text "lineage_run_ids"
    t.float "max_ram"
    t.integer "nber_cores"
    t.integer "num"
    t.text "output_json", default: "{}"
    t.integer "pid"
    t.text "pipeline_parent_run_ids", default: ""
    t.bigint "pred_max_ram"
    t.text "pred_params_json"
    t.integer "pred_process_duration"
    t.float "process_duration"
    t.integer "process_idle_duration"
    t.integer "project_id"
    t.integer "req_id"
    t.boolean "return_stdout", default: false
    t.text "run_children_json"
    t.integer "run_id"
    t.text "run_parents_json"
    t.datetime "start_time", precision: nil
    t.integer "status_id"
    t.integer "std_method_id"
    t.integer "step_id"
    t.datetime "submitted_at", precision: nil
    t.integer "user_id"
    t.float "waiting_duration"
    t.index ["project_id"], name: "project_id_del_runs"
  end

  create_table "delayed_jobs", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", precision: nil
    t.datetime "failed_at", precision: nil
    t.text "handler", null: false
    t.text "last_error"
    t.datetime "locked_at", precision: nil
    t.string "locked_by"
    t.integer "priority", default: 0, null: false
    t.string "queue"
    t.datetime "run_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index ["priority", "run_at"], name: "delayed_jobs_priority"
  end

  create_table "diff_expr_methods", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.boolean "creates_av_norm", default: false
    t.text "description"
    t.boolean "handles_log", default: false
    t.text "label"
    t.text "link"
    t.text "name"
    t.text "program"
    t.integer "speed_id", limit: 2
    t.datetime "updated_at", precision: nil
  end

  create_table "diff_exprs", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.integer "diff_expr_method_id"
    t.integer "duration"
    t.text "error"
    t.integer "job_id"
    t.text "label"
    t.text "md5_sel1"
    t.text "md5_sel2"
    t.integer "nb_cells_sel1"
    t.integer "nb_cells_sel2"
    t.integer "nber_down_genes"
    t.integer "nber_up_genes"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "selection1_id"
    t.integer "selection2_id"
    t.text "short_label"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "dim_reductions", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.boolean "dim_reduction", default: false
    t.text "label"
    t.text "link"
    t.text "name"
    t.text "program"
    t.integer "rank"
    t.integer "speed_id", limit: 2
    t.datetime "updated_at", precision: nil
  end

  create_table "direct_links", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.integer "nber_views", default: 0
    t.text "params_json"
    t.integer "project_id"
    t.datetime "updated_at", precision: nil
    t.text "view_key"
  end

  create_table "docker_images", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "full_name"
    t.text "name"
    t.text "tag"
    t.text "tools_json"
    t.datetime "updated_at", precision: nil
    t.integer "version"
  end

  create_table "docker_patches", id: :serial, force: :cascade do |t|
    t.datetime "activated_at", precision: nil
    t.text "container_name"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "std_method_ids"
    t.text "step_ids"
    t.integer "tag"
    t.datetime "updated_at", precision: nil
    t.integer "version_id"
  end

  create_table "docker_versions", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.text "tag"
    t.text "tools_json"
    t.datetime "updated_at", precision: nil
    t.integer "version"
  end

  create_table "ensembl_subdomains", id: :serial, force: :cascade do |t|
    t.integer "latest_ensembl_release"
    t.text "name"
    t.text "url"
  end

  create_table "ensembl_subdomains_old", id: :integer, default: -> { "nextval('ensembl_subdomains_id_seq'::regclass)" }, force: :cascade do |t|
    t.integer "latest_ensembl_release"
    t.text "name"
    t.text "url"
  end

  create_table "exp_entries", id: :integer, default: -> { "nextval('geo_entries_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "contact_emails"
    t.text "contributors"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "doi"
    t.text "identifier"
    t.integer "identifier_type_id"
    t.text "identifiers_json"
    t.text "pmid"
    t.text "srp"
    t.datetime "submitted_at", precision: nil
    t.text "title"
    t.datetime "updated_at", precision: nil
  end

  create_table "exp_entries_projects", id: false, force: :cascade do |t|
    t.integer "exp_entry_id"
    t.integer "project_id"
  end

  create_table "exp_entries_sample_identifiers", id: false, force: :cascade do |t|
    t.integer "exp_entry_id"
    t.integer "sample_identifier_id"
  end

  create_table "exp_entry_identifiers", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.integer "exp_entry_id"
    t.text "identifier"
    t.integer "identifier_type_id"
    t.datetime "updated_at", precision: nil
  end

  create_table "file_formats", id: :serial, force: :cascade do |t|
    t.text "child_format"
    t.text "color"
    t.text "description"
    t.text "ext"
    t.integer "introduced_in_version_id"
    t.text "label"
    t.boolean "many_files"
    t.text "name"
    t.boolean "parsing_mandatory_sel"
  end

  create_table "filter_methods", id: :integer, default: -> { "nextval('filters_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.boolean "handles_log", default: false
    t.text "label"
    t.text "link"
    t.text "name"
    t.text "program"
    t.integer "speed_id", limit: 2
    t.datetime "updated_at", precision: nil
  end

  create_table "fos", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "ext"
    t.text "filepath"
    t.bigint "filesize"
    t.integer "project_id"
    t.integer "run_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
  end

  create_table "fus", id: :integer, default: -> { "nextval('courses_id_seq'::regclass)" }, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.integer "preparsing_version_id"
    t.integer "project_id"
    t.text "project_key"
    t.text "status"
    t.datetime "updated_at", precision: nil
    t.text "upload_content_type"
    t.text "upload_file_name"
    t.bigint "upload_file_size"
    t.integer "upload_type"
    t.datetime "upload_updated_at", precision: nil
    t.text "url"
    t.integer "user_id"
    t.boolean "visible"
    t.index ["preparsing_version_id"], name: "index_fus_on_preparsing_version_id"
  end

  create_table "gene_enrichments", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.integer "diff_expr_id"
    t.integer "duration"
    t.text "error"
    t.integer "job_id"
    t.text "label"
    t.integer "nber_pathways"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
  end

  create_table "gene_filterings", id: :integer, default: -> { "nextval('filterings_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "filter_method_id"
    t.integer "job_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "gene_set_collection_types", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "icon", null: false
    t.string "icon_color", null: false
    t.string "key", null: false
    t.string "label", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_gene_set_collection_types_on_key", unique: true
  end

  create_table "gene_set_collections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "file_key", null: false
    t.bigint "gene_set_collection_type_id", null: false
    t.string "name", null: false
    t.integer "project_id", null: false
    t.string "source_kind", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["file_key"], name: "index_gene_set_collections_on_file_key", unique: true
    t.index ["gene_set_collection_type_id"], name: "index_gene_set_collections_on_gene_set_collection_type_id"
    t.index ["project_id", "gene_set_collection_type_id"], name: "index_gene_set_collections_on_project_and_type"
    t.index ["project_id", "source_kind"], name: "index_gene_set_collections_on_project_id_and_source_kind"
    t.index ["project_id"], name: "index_gene_set_collections_on_project_id"
    t.index ["user_id"], name: "index_gene_set_collections_on_user_id"
  end

  create_table "guided_tour_steps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "exclude_from_page_replay", default: false, null: false
    t.string "focus_element", null: false
    t.bigint "guided_tour_id", null: false
    t.string "page_url", null: false
    t.integer "rank", null: false
    t.jsonb "step_actions", default: [], null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["guided_tour_id", "rank"], name: "index_guided_tour_steps_on_guided_tour_id_and_rank", unique: true
    t.index ["guided_tour_id"], name: "index_guided_tour_steps_on_guided_tour_id"
  end

  create_table "guided_tours", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_time"
    t.boolean "hidden", default: false, null: false
    t.string "name", null: false
    t.integer "rank", null: false
    t.datetime "updated_at", null: false
    t.index ["rank"], name: "index_guided_tours_on_rank"
  end

  create_table "heatmaps", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "job_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "identifier_types", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.boolean "pluralizable", default: false
    t.text "prefix"
    t.datetime "updated_at", precision: nil
    t.text "url_mask"
  end

  create_table "imputation_methods", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.boolean "hidden", default: false
    t.boolean "is_parallelized"
    t.text "label"
    t.text "name"
    t.text "program"
    t.integer "speed_id", limit: 2
    t.datetime "updated_at", precision: nil
  end

  create_table "imputations", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "imputation_method_id"
    t.integer "job_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "info_types", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "label"
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "ips", id: :serial, force: :cascade do |t|
    t.text "ip"
    t.text "key"
  end

  create_table "ips_users", id: false, force: :cascade do |t|
    t.integer "ip_id"
    t.integer "user_id"
  end

  create_table "jobs", id: :serial, force: :cascade do |t|
    t.integer "cloned_job_id"
    t.text "command_line"
    t.datetime "created_at", precision: nil
    t.integer "delayed_job_id"
    t.integer "duration"
    t.integer "pid"
    t.integer "project_id"
    t.integer "speed_id"
    t.integer "status_id"
    t.integer "step_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
  end

  create_table "journals", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "ncbi_taxonomy_nodes", primary_key: "tax_id", id: :serial, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "order_tax_id"
    t.integer "parent_tax_id"
    t.string "rank", default: "", null: false
    t.string "scientific_name", default: "", null: false
    t.datetime "updated_at", null: false
    t.index ["order_tax_id"], name: "index_ncbi_taxonomy_nodes_on_order_tax_id"
    t.index ["parent_tax_id"], name: "index_ncbi_taxonomy_nodes_on_parent_tax_id"
    t.index ["rank"], name: "index_ncbi_taxonomy_nodes_on_rank"
  end

  create_table "normalizations", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "job_id"
    t.integer "norm_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "norms", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.boolean "handles_log", default: false
    t.boolean "hidden", default: false
    t.text "label"
    t.text "link"
    t.text "name"
    t.boolean "output_is_log", default: true
    t.text "program"
    t.integer "speed_id", limit: 2
    t.datetime "updated_at", precision: nil
  end

  create_table "ontology_term_types", id: :serial, force: :cascade do |t|
    t.string "auto_from_project"
    t.text "cell_ontology_ids"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.integer "display_order", default: 99
    t.text "field_group_id"
    t.string "field_type", default: "col_attr"
    t.text "free_text_json"
    t.text "in_lineage_term_ids"
    t.text "label"
    t.string "label_path"
    t.boolean "multi_value", default: false
    t.text "name"
    t.integer "rank"
    t.string "term_format_hint"
    t.text "term_ids"
    t.string "term_path"
    t.text "term_valid_values_json"
    t.datetime "updated_at", precision: nil
  end

  create_table "orcid_users", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "key"
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "organisms", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "ensembl_db_name"
    t.integer "ensembl_subdomain_id"
    t.text "genrep_key"
    t.text "go_short_name"
    t.integer "latest_ensembl_release"
    t.text "name"
    t.text "short_name"
    t.text "tag"
    t.integer "tax_id"
    t.datetime "updated_at", precision: nil
  end

  create_table "organisms_bkp", id: :integer, default: nil, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "ensembl_db_name"
    t.integer "ensembl_subdomain_id"
    t.text "genrep_key"
    t.text "go_short_name"
    t.integer "latest_ensembl_release"
    t.text "name"
    t.text "short_name"
    t.text "tag"
    t.integer "tax_id"
    t.datetime "updated_at", precision: nil
  end

  create_table "ot_projects", id: :serial, force: :cascade do |t|
    t.integer "annot_id"
    t.integer "cell_ontology_term_id"
    t.datetime "created_at", precision: nil
    t.text "free_text"
    t.integer "ontology_term_type_id"
    t.integer "project_id"
    t.datetime "updated_at", precision: nil
    t.index ["project_id", "annot_id"], name: "idx_ot_projects_project_annot"
  end

  create_table "ott_projects", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.boolean "not_applicable"
    t.integer "ontology_term_type_id"
    t.integer "project_id"
    t.datetime "updated_at", precision: nil
  end

  create_table "output_attrs", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "project_cell_sets", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "key"
    t.text "nber_cells"
    t.datetime "updated_at", precision: nil
    t.index ["key"], name: "key_project_cell_sets"
  end

  create_table "project_dim_reductions", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.integer "dim_reduction_id"
    t.integer "duration"
    t.integer "job_id"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "project_infos", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.integer "info_type_id"
    t.datetime "updated_at", precision: nil
    t.text "value"
  end

  create_table "project_steps", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "error_message"
    t.integer "job_id"
    t.text "nber_runs_json", default: "{}"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "step_id"
    t.datetime "updated_at", precision: nil
    t.index ["project_id", "step_id"], name: "index_project_steps_on_project_id_and_step_id", unique: true
  end

  create_table "project_tags", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "project_tags_projects", id: false, force: :cascade do |t|
    t.integer "project_id"
    t.integer "project_tag_id"
  end

  create_table "project_types", id: :serial, force: :cascade do |t|
    t.text "col_label"
    t.datetime "created_at", precision: nil
    t.text "name"
    t.text "row_label"
    t.text "tag"
    t.datetime "updated_at", precision: nil
  end

  create_table "project_view_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.date "viewed_on", null: false
    t.string "viewer_token", limit: 128, null: false
    t.index ["project_id", "viewed_on"], name: "index_project_view_logs_on_project_id_and_viewed_on"
    t.index ["project_id", "viewer_token", "viewed_on"], name: "idx_pvl_on_project_viewer_day", unique: true
    t.index ["project_id"], name: "index_project_view_logs_on_project_id"
  end

  create_table "projects", id: :serial, force: :cascade do |t|
    t.integer "archive_status_id", default: 1
    t.boolean "being_deleted", default: false
    t.integer "cloned_project_id"
    t.datetime "created_at", precision: nil
    t.text "de_filter_json"
    t.integer "delayed_job_id"
    t.text "description"
    t.bigint "disk_size"
    t.bigint "disk_size_archive"
    t.bigint "disk_size_archived"
    t.text "doi"
    t.integer "duration"
    t.text "error_message"
    t.string "extension", limit: 6, default: "txt"
    t.text "extra_info"
    t.text "filter_attrs_json"
    t.integer "filter_id"
    t.text "filter_method_attrs_json"
    t.integer "filter_method_id"
    t.integer "filtering_job_id"
    t.datetime "frozen_at", precision: nil
    t.integer "fu_id"
    t.text "ge_filter_json"
    t.text "graph_json"
    t.text "group_filename"
    t.text "input_filename"
    t.text "key"
    t.text "landing_page_json", default: "{}"
    t.text "landing_page_key"
    t.text "last_day_session_ids", default: ""
    t.datetime "modified_at", precision: nil
    t.text "name"
    t.integer "nber_cloned", default: 0
    t.integer "nber_cols"
    t.integer "nber_rows"
    t.text "nber_runs_json", default: "{}"
    t.integer "nber_views", default: 0
    t.text "norm_attrs_json"
    t.integer "norm_id"
    t.integer "normalization_job_id"
    t.integer "organism_id", default: 1
    t.text "parsing_attrs_json"
    t.integer "parsing_job_id"
    t.integer "pid"
    t.integer "pmid"
    t.integer "project_cell_set_id"
    t.integer "project_type_id"
    t.boolean "public", default: false
    t.datetime "public_at", precision: nil
    t.integer "public_id"
    t.text "read_access"
    t.text "replaced_by_comment"
    t.text "replaced_by_project_key"
    t.integer "root_project_id"
    t.boolean "sandbox", default: false
    t.integer "session_id"
    t.integer "status_id", default: 1
    t.integer "step", limit: 2
    t.integer "step_id", default: 1
    t.text "technology"
    t.text "tissue"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.integer "version_id"
    t.datetime "viewed_at", precision: nil, default: -> { "now()" }
    t.text "write_access"
    t.index ["root_project_id"], name: "index_projects_on_root_project_id"
  end

  create_table "projects_provider_projects", id: false, force: :cascade do |t|
    t.integer "project_id"
    t.integer "provider_project_id"
  end

  create_table "provider_projects", id: :integer, default: -> { "nextval('hca_projects_id_seq'::regclass)" }, force: :cascade do |t|
    t.text "attrs_json", default: "{}"
    t.text "comment"
    t.text "filename"
    t.text "key"
    t.boolean "not_add_in_asap", default: false
    t.integer "provider_id"
    t.text "title"
  end

  create_table "providers", id: :serial, force: :cascade do |t|
    t.text "attrs_json", default: "{}"
    t.text "description"
    t.text "name"
    t.text "tag"
    t.text "url"
    t.text "url_mask"
  end

  create_table "ratings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "display_publicly", default: false, null: false
    t.text "review"
    t.integer "stars", null: false
    t.datetime "updated_at", null: false
    t.boolean "use_for_funding", default: false, null: false
    t.integer "user_id", null: false
    t.index ["stars"], name: "index_ratings_on_stars"
    t.index ["user_id"], name: "index_ratings_on_user_id"
  end

  create_table "reqs", id: :serial, force: :cascade do |t|
    t.text "attrs_json", default: "{}"
    t.datetime "created_at", precision: nil
    t.integer "delayed_job_id"
    t.text "error"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "std_method_id"
    t.integer "step_id"
    t.integer "user_id"
  end

  create_table "runs", id: :serial, force: :cascade do |t|
    t.boolean "async", default: true
    t.text "attrs_json", default: "{}"
    t.text "children_run_ids", default: ""
    t.integer "cloned_run_id"
    t.text "command_json"
    t.datetime "created_at", precision: nil
    t.float "duration"
    t.text "error"
    t.text "lineage_run_ids", default: ""
    t.float "max_ram"
    t.integer "nber_cores"
    t.integer "num"
    t.text "output_json", default: "{}"
    t.integer "pid"
    t.text "pipeline_parent_run_ids", default: ""
    t.bigint "pred_max_ram"
    t.text "pred_params_json"
    t.integer "pred_process_duration"
    t.float "process_duration"
    t.integer "process_idle_duration"
    t.integer "project_id"
    t.integer "req_id"
    t.boolean "return_stdout", default: false
    t.text "run_children_json"
    t.text "run_parents_json"
    t.integer "slurm_job_id"
    t.datetime "start_time", precision: nil
    t.integer "status_id"
    t.integer "std_method_id"
    t.integer "step_id"
    t.datetime "submitted_at", precision: nil
    t.integer "user_id"
    t.float "waiting_duration"
    t.index ["slurm_job_id"], name: "index_runs_on_slurm_job_id"
  end

  create_table "sample_identifiers", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "identifier"
    t.integer "identifier_type_id"
    t.datetime "updated_at", precision: nil
  end

  create_table "selections", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.boolean "edited", default: false
    t.text "label"
    t.integer "manual_num"
    t.text "md5"
    t.integer "nb_items"
    t.integer "obj_id"
    t.integer "obj_num"
    t.integer "project_id"
    t.integer "selection_type_id", default: 1
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
  end

  create_table "sessions", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "data"
    t.string "session_id", null: false
    t.datetime "updated_at", precision: nil
    t.index ["session_id"], name: "index_sessions_on_session_id", unique: true
    t.index ["updated_at"], name: "index_sessions_on_updated_at"
  end

  create_table "shares", id: :serial, force: :cascade do |t|
    t.boolean "analyze_perm", default: false
    t.boolean "clone_perm"
    t.datetime "created_at", precision: nil
    t.boolean "download_perm"
    t.text "email"
    t.boolean "export_perm", default: false
    t.integer "project_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.boolean "view_perm", default: true
  end

  create_table "speeds", id: :serial, force: :cascade do |t|
    t.text "logo"
    t.text "name"
  end

  create_table "statuses", id: :serial, force: :cascade do |t|
    t.text "active_color"
    t.text "badge_bg_class"
    t.text "badge_text_class"
    t.text "color"
    t.text "display_label"
    t.text "icon_class"
    t.text "icon_spin"
    t.text "img_extension"
    t.text "inactive_color"
    t.text "label"
    t.text "name"
    t.integer "rank"
  end

  create_table "std_methods", id: :serial, force: :cascade do |t|
    t.boolean "async"
    t.text "attr_layout_json", default: "[]"
    t.text "attrs_json", default: "{}"
    t.text "command_json", default: "{}"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.integer "docker_image_id"
    t.text "label"
    t.text "link"
    t.text "name"
    t.integer "nber_cores"
    t.text "obj_attrs_json", default: "{}"
    t.boolean "obsolete", default: false
    t.text "output_json", default: "{}"
    t.text "program"
    t.text "short_label"
    t.integer "speed_id", limit: 2
    t.integer "step_id"
    t.datetime "updated_at", precision: nil
    t.integer "version_id"
  end

  create_table "std_runs", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "job_id"
    t.integer "num"
    t.text "output_json", default: "{}"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "std_method_id"
    t.integer "step_id"
    t.integer "user_id"
  end

  create_table "steps", id: :serial, force: :cascade do |t|
    t.boolean "admin", default: false
    t.text "attrs_json", default: "{}"
    t.text "color"
    t.text "command_json", default: "{}"
    t.text "dashboard_card_json", default: "{}"
    t.text "description"
    t.integer "docker_image_id"
    t.text "group_name"
    t.boolean "has_std_dashboard", default: true
    t.boolean "has_std_form", default: true
    t.boolean "has_std_view", default: true
    t.boolean "hidden", default: false
    t.boolean "is_std_step", default: true
    t.text "label"
    t.text "method_attrs_json", default: "{}"
    t.text "method_obj_name"
    t.boolean "multiple_runs", default: true
    t.text "name"
    t.text "obj_name"
    t.text "output_json", default: "{}"
    t.integer "rank"
    t.text "show_view_json", default: "{}"
    t.text "tag"
    t.integer "version_id"
    t.text "warnings"
  end

  create_table "tmp_fos", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "ext"
    t.text "filepath"
    t.bigint "filesize"
    t.integer "project_id"
    t.integer "run_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
  end

  create_table "tmp_genes", id: :serial, force: :cascade do |t|
    t.text "alt_names"
    t.text "biotype"
    t.text "chr"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "ensembl_id"
    t.integer "gene_length"
    t.integer "latest_ensembl_release"
    t.text "name"
    t.integer "ncbi_gene_id"
    t.text "obsolete_alt_names"
    t.integer "organism_id"
    t.integer "sum_exon_length"
    t.datetime "updated_at", precision: nil
    t.index ["ensembl_id"], name: "tmp_genes_ensembl_id_idx"
    t.index ["name"], name: "tmp_genes_name_idx"
  end

  create_table "todo_types", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "label"
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "todo_votes", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.integer "todo_id"
    t.integer "user_id"
  end

  create_table "todos", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "description"
    t.integer "nber_votes", default: 0
    t.integer "status_id", default: 1
    t.text "title"
    t.integer "todo_type_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
    t.boolean "validated", default: false
  end

  create_table "tool_types", id: :serial, force: :cascade do |t|
    t.text "name"
  end

  create_table "tools", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "label"
    t.text "name"
    t.text "package"
    t.text "step_ids"
    t.text "tag"
    t.text "title"
    t.integer "tool_type_id"
    t.datetime "updated_at", precision: nil
    t.text "url"
  end

  create_table "trajectories", id: :serial, force: :cascade do |t|
    t.text "attrs_json"
    t.datetime "created_at", precision: nil
    t.text "error"
    t.integer "job_id"
    t.integer "num"
    t.integer "pid"
    t.integer "project_id"
    t.integer "status_id"
    t.integer "user_id"
  end

  create_table "upload_types", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.datetime "updated_at", precision: nil
  end

  create_table "uploads", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "name"
    t.integer "project_id"
    t.text "status"
    t.datetime "updated_at", precision: nil
    t.text "upload_content_type"
    t.text "upload_file_name"
    t.integer "upload_file_size"
    t.integer "upload_type"
    t.datetime "upload_updated_at", precision: nil
    t.boolean "visible"
  end

  create_table "user_types", id: :serial, force: :cascade do |t|
    t.integer "max_nber_cpus"
    t.integer "max_total_memory"
    t.text "name"
  end

  create_table "users", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.datetime "current_sign_in_at", precision: nil
    t.inet "current_sign_in_ip"
    t.text "displayed_name"
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "last_sign_in_at", precision: nil
    t.inet "last_sign_in_ip"
    t.integer "orcid_user_id"
    t.datetime "remember_created_at", precision: nil
    t.datetime "reset_password_sent_at", precision: nil
    t.string "reset_password_token"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "updated_at", precision: nil
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "versions", id: :serial, force: :cascade do |t|
    t.boolean "activated", default: false
    t.datetime "activated_at", precision: nil
    t.boolean "beta", default: true
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "docker_json"
    t.text "env_json"
    t.datetime "release_date", precision: nil
    t.integer "step_id"
    t.integer "tool_type_id"
    t.text "tools_json"
    t.datetime "updated_at", precision: nil
  end

  add_foreign_key "active_runs", "projects", name: "active_runs_project_id_fkey"
  add_foreign_key "active_runs", "reqs", name: "active_runs_req_id_fkey"
  add_foreign_key "active_runs", "runs", name: "active_runs_run_id_fkey"
  add_foreign_key "active_runs", "statuses", name: "active_runs_status_id_fkey"
  add_foreign_key "active_runs", "std_methods", name: "active_runs_std_method_id_fkey"
  add_foreign_key "active_runs", "steps", name: "active_runs_step_id_fkey"
  add_foreign_key "active_runs", "users", name: "active_runs_user_id_fkey"
  add_foreign_key "annot_cell_sets", "annots", name: "annot_cell_sets_annot_id_fkey"
  add_foreign_key "annot_cell_sets", "cell_sets", name: "annot_cell_sets_cell_set_id_fkey"
  add_foreign_key "annot_cell_sets", "projects", name: "annot_cell_sets_project_id_fkey"
  add_foreign_key "annots", "attr_outputs", name: "annots_attr_output_id_fkey"
  add_foreign_key "annots", "data_transformations"
  add_foreign_key "annots", "data_types", name: "annots_data_type_id_fkey"
  add_foreign_key "annots", "output_attrs", name: "annots_output_attr_id_fkey"
  add_foreign_key "annots", "projects", name: "annots_project_id_fkey"
  add_foreign_key "annots", "runs", name: "annots_run_id_fkey"
  add_foreign_key "annots", "steps", name: "annots_step_id_fkey"
  add_foreign_key "annots", "users", name: "annots_user_id_fkey"
  add_foreign_key "articles", "journals", name: "articles_journal_id_fkey"
  add_foreign_key "articles_projects", "articles", name: "articles_projects_article_id_fkey"
  add_foreign_key "articles_projects", "projects", name: "articles_projects_project_id_fkey"
  add_foreign_key "cell_filterings", "jobs", name: "cell_filterings_job_id_fkey"
  add_foreign_key "cell_filterings", "projects", name: "cell_filterings_project_id_fkey"
  add_foreign_key "cell_filterings", "statuses", name: "cell_filterings_status_id_fkey"
  add_foreign_key "cell_filterings", "users", name: "cell_filterings_user_id_fkey"
  add_foreign_key "cell_ontologies_organisms", "cell_ontologies", name: "cell_ontologies_organisms_cell_ontology_id_fkey"
  add_foreign_key "cell_ontologies_organisms", "organisms_bkp", column: "organism_id", name: "cell_ontologies_organisms_organism_id_fkey"
  add_foreign_key "cell_ontology_terms", "cell_ontologies", name: "cell_ontology_terms_cell_ontology_id_fkey"
  add_foreign_key "cell_sets", "project_cell_sets", name: "cell_sets_project_cell_set_id_fkey"
  add_foreign_key "checkpoints", "projects"
  add_foreign_key "checkpoints", "users"
  add_foreign_key "cla_votes", "cla_sources", name: "cla_votes_cla_source_id_fkey"
  add_foreign_key "cla_votes", "clas", name: "cla_votes_cla_id_fkey"
  add_foreign_key "cla_votes", "orcid_users", name: "cla_votes_orcid_user_id_fkey"
  add_foreign_key "cla_votes", "users", name: "cla_votes_user_id_fkey"
  add_foreign_key "clas", "cell_sets", name: "clas_cell_set_id_fkey"
  add_foreign_key "clas", "cla_sources", name: "clas_cla_source_id_fkey"
  add_foreign_key "clas", "clas", column: "clone_id", name: "clas_clone_id_fkey"
  add_foreign_key "clas", "ontology_term_types", name: "clas_ontology_term_type_id_fkey"
  add_foreign_key "clas", "orcid_users", name: "clas_orcid_user_id_fkey"
  add_foreign_key "clas", "users", name: "clas_user_id_fkey"
  add_foreign_key "cluster_methods", "speeds", name: "cluster_methods_speed_id_fkey"
  add_foreign_key "clusters", "cluster_methods", name: "clusters_cluster_method_id_fkey"
  add_foreign_key "clusters", "dim_reductions", name: "clusters_dim_reduction_id_fkey"
  add_foreign_key "clusters", "jobs", name: "clusters_job_id_fkey"
  add_foreign_key "clusters", "projects", name: "clusters_project_id_fkey"
  add_foreign_key "clusters", "statuses", name: "clusters_status_id_fkey"
  add_foreign_key "clusters", "steps", name: "clusters_step_id_fkey"
  add_foreign_key "clusters", "users", name: "clusters_user_id_fkey"
  add_foreign_key "compliance_mappings", "ontology_term_types", name: "compliance_mappings_ontology_term_type_id_fkey"
  add_foreign_key "compliance_term_replacements", "compliance_mappings"
  add_foreign_key "correlations", "jobs", name: "correlations_job_id_fkey"
  add_foreign_key "correlations", "projects", name: "correlations_project_id_fkey"
  add_foreign_key "correlations", "statuses", name: "correlations_status_id_fkey"
  add_foreign_key "correlations", "users", name: "correlations_user_id_fkey"
  add_foreign_key "covariates", "jobs", name: "covariates_job_id_fkey"
  add_foreign_key "covariates", "projects", name: "covariates_project_id_fkey"
  add_foreign_key "covariates", "statuses", name: "covariates_status_id_fkey"
  add_foreign_key "covariates", "users", name: "covariates_user_id_fkey"
  add_foreign_key "db_sets", "tools", name: "db_sets_tool_id_fkey"
  add_foreign_key "del_runs", "statuses", name: "del_runs_status_id_fkey"
  add_foreign_key "del_runs", "std_methods", name: "del_runs_std_method_id_fkey"
  add_foreign_key "del_runs", "steps", name: "del_runs_step_id_fkey"
  add_foreign_key "del_runs", "users", name: "del_runs_user_id_fkey"
  add_foreign_key "diff_expr_methods", "speeds", name: "diff_expr_methods_speed_id_fkey"
  add_foreign_key "diff_exprs", "diff_expr_methods", name: "diff_exprs_diff_expr_method_id_fkey"
  add_foreign_key "diff_exprs", "jobs", name: "diff_exprs_job_id_fkey"
  add_foreign_key "diff_exprs", "projects", name: "diff_exprs_project_id_fkey"
  add_foreign_key "diff_exprs", "statuses", name: "diff_exprs_status_id_fkey"
  add_foreign_key "diff_exprs", "users", name: "diff_exprs_user_id_fkey"
  add_foreign_key "dim_reductions", "speeds", name: "dim_reductions_speed_id_fkey"
  add_foreign_key "direct_links", "projects", name: "direct_links_project_id_fkey"
  add_foreign_key "docker_patches", "versions", name: "docker_patches_version_id_fkey"
  add_foreign_key "exp_entries", "identifier_types", name: "geo_entries_identifier_type_id_fkey"
  add_foreign_key "exp_entries_projects", "exp_entries", name: "geo_entries_projects_geo_entry_id_fkey"
  add_foreign_key "exp_entries_projects", "projects", name: "geo_entries_projects_project_id_fkey"
  add_foreign_key "exp_entries_sample_identifiers", "exp_entries", name: "geo_entries_sample_identifiers_geo_entry_id_fkey"
  add_foreign_key "exp_entries_sample_identifiers", "sample_identifiers", name: "geo_entries_sample_identifiers_sample_identifier_id_fkey"
  add_foreign_key "exp_entry_identifiers", "exp_entries", name: "exp_entry_identifiers_exp_entry_id_fkey"
  add_foreign_key "exp_entry_identifiers", "identifier_types", name: "exp_entry_identifiers_identifier_type_id_fkey"
  add_foreign_key "filter_methods", "speeds", name: "filters_speed_id_fkey"
  add_foreign_key "fos", "projects", name: "fos_project_id_fkey"
  add_foreign_key "fos", "runs", name: "fos_run_id_fkey"
  add_foreign_key "fos", "users", name: "fos_user_id_fkey"
  add_foreign_key "fus", "projects", name: "courses_project_id_fkey"
  add_foreign_key "fus", "users", name: "fus_user_id_fkey"
  add_foreign_key "gene_enrichments", "diff_exprs", name: "gene_enrichments_diff_expr_id_fkey"
  add_foreign_key "gene_enrichments", "jobs", name: "gene_enrichments_job_id_fkey"
  add_foreign_key "gene_enrichments", "projects", name: "gene_enrichments_project_id_fkey"
  add_foreign_key "gene_enrichments", "statuses", name: "gene_enrichments_status_id_fkey"
  add_foreign_key "gene_enrichments", "users", name: "gene_enrichments_user_id_fkey"
  add_foreign_key "gene_filterings", "jobs", name: "filterings_job_id_fkey"
  add_foreign_key "gene_filterings", "norms", column: "filter_method_id", name: "filterings_filter_method_id_fkey"
  add_foreign_key "gene_filterings", "projects", name: "filterings_project_id_fkey"
  add_foreign_key "gene_filterings", "statuses", name: "filterings_status_id_fkey"
  add_foreign_key "gene_filterings", "users", name: "filterings_user_id_fkey"
  add_foreign_key "gene_set_collections", "gene_set_collection_types"
  add_foreign_key "guided_tour_steps", "guided_tours"
  add_foreign_key "heatmaps", "jobs", name: "heatmaps_job_id_fkey"
  add_foreign_key "heatmaps", "projects", name: "heatmaps_project_id_fkey"
  add_foreign_key "heatmaps", "statuses", name: "heatmaps_status_id_fkey"
  add_foreign_key "heatmaps", "users", name: "heatmaps_user_id_fkey"
  add_foreign_key "imputation_methods", "speeds", name: "imputation_methods_speed_id_fkey"
  add_foreign_key "imputations", "imputation_methods", name: "imputations_imputation_method_id_fkey"
  add_foreign_key "imputations", "jobs", name: "imputations_job_id_fkey"
  add_foreign_key "imputations", "projects", name: "imputations_project_id_fkey"
  add_foreign_key "imputations", "statuses", name: "imputations_status_id_fkey"
  add_foreign_key "imputations", "users", name: "imputations_user_id_fkey"
  add_foreign_key "ips_users", "ips", name: "ips_users_ip_id_fkey"
  add_foreign_key "ips_users", "users", name: "ips_users_user_id_fkey"
  add_foreign_key "jobs", "speeds", name: "jobs_speed_id_fkey"
  add_foreign_key "jobs", "statuses", name: "jobs_status_id_fkey"
  add_foreign_key "jobs", "steps", name: "jobs_step_id_fkey"
  add_foreign_key "jobs", "users", name: "jobs_user_id_fkey"
  add_foreign_key "normalizations", "jobs", name: "normalizations_job_id_fkey"
  add_foreign_key "normalizations", "norms", name: "normalizations_norm_id_fkey"
  add_foreign_key "normalizations", "projects", name: "normalizations_project_id_fkey"
  add_foreign_key "normalizations", "statuses", name: "normalizations_status_id_fkey"
  add_foreign_key "normalizations", "users", name: "normalizations_user_id_fkey"
  add_foreign_key "norms", "speeds", name: "norms_speed_id_fkey"
  add_foreign_key "organisms", "ensembl_subdomains", name: "organisms_ensembl_subdomain_id_fkey"
  add_foreign_key "organisms_bkp", "ensembl_subdomains_old", column: "ensembl_subdomain_id", name: "organisms_ensembl_subdomain_id_fkey"
  add_foreign_key "ot_projects", "annots", name: "ot_projects_annot_id_fkey"
  add_foreign_key "ot_projects", "cell_ontology_terms", name: "ot_projects_cell_ontology_term_id_fkey"
  add_foreign_key "ot_projects", "ontology_term_types", name: "ot_projects_ontology_term_type_id_fkey"
  add_foreign_key "ot_projects", "projects", name: "ot_projects_project_id_fkey"
  add_foreign_key "ott_projects", "ontology_term_types", name: "ott_projects_ontology_term_type_id_fkey"
  add_foreign_key "ott_projects", "projects", name: "ott_projects_project_id_fkey"
  add_foreign_key "project_dim_reductions", "dim_reductions", name: "project_dim_reductions_dim_reduction_id_fkey"
  add_foreign_key "project_dim_reductions", "jobs", name: "project_dim_reductions_job_id_fkey"
  add_foreign_key "project_dim_reductions", "projects", name: "project_dim_reductions_project_id_fkey"
  add_foreign_key "project_dim_reductions", "statuses", name: "project_dim_reductions_status_id_fkey"
  add_foreign_key "project_dim_reductions", "users", name: "project_dim_reductions_user_id_fkey"
  add_foreign_key "project_infos", "info_types", name: "project_infos_info_type_id_fkey"
  add_foreign_key "project_steps", "jobs", name: "project_steps_job_id_fkey"
  add_foreign_key "project_steps", "projects", name: "project_steps_project_id_fkey"
  add_foreign_key "project_steps", "statuses", name: "project_steps_status_id_fkey"
  add_foreign_key "project_steps", "steps", name: "project_steps_step_id_fkey"
  add_foreign_key "project_tags_projects", "project_tags", name: "project_tags_projects_project_tag_id_fkey"
  add_foreign_key "project_tags_projects", "projects", name: "project_tags_projects_project_id_fkey"
  add_foreign_key "project_view_logs", "projects"
  add_foreign_key "projects", "archive_statuses", name: "projects_archive_status_id_fkey"
  add_foreign_key "projects", "filter_methods", column: "filter_id", name: "projects_filter_id_fkey"
  add_foreign_key "projects", "filter_methods", name: "projects_filter_method_id_fkey"
  add_foreign_key "projects", "norms", name: "projects_norm_id_fkey"
  add_foreign_key "projects", "organisms", name: "fk_organism_id"
  add_foreign_key "projects", "project_cell_sets", name: "projects_project_cell_set_id_fkey"
  add_foreign_key "projects", "project_types", name: "projects_project_type_id_fkey"
  add_foreign_key "projects", "projects", column: "root_project_id", on_delete: :nullify
  add_foreign_key "projects", "statuses", name: "projects_status_id_fkey"
  add_foreign_key "projects", "steps", name: "projects_step_id_fkey"
  add_foreign_key "projects", "users", name: "projects_user_id_fkey"
  add_foreign_key "projects", "versions", name: "projects_version_id_fkey"
  add_foreign_key "projects_provider_projects", "projects", name: "hca_projects_projects_project_id_fkey"
  add_foreign_key "projects_provider_projects", "provider_projects", name: "hca_projects_projects_hca_project_id_fkey"
  add_foreign_key "provider_projects", "providers", name: "hca_projects_provider_id_fkey"
  add_foreign_key "reqs", "projects", name: "reqs_project_id_fkey"
  add_foreign_key "reqs", "std_methods", name: "reqs_std_method_id_fkey"
  add_foreign_key "reqs", "steps", name: "reqs_step_id_fkey"
  add_foreign_key "reqs", "users", name: "reqs_user_id_fkey"
  add_foreign_key "runs", "projects", name: "runs_project_id_fkey"
  add_foreign_key "runs", "reqs", name: "runs_req_id_fkey"
  add_foreign_key "runs", "statuses", name: "runs_status_id_fkey"
  add_foreign_key "runs", "std_methods", name: "runs_std_method_id_fkey"
  add_foreign_key "runs", "steps", name: "runs_step_id_fkey"
  add_foreign_key "runs", "users", name: "runs_user_id_fkey"
  add_foreign_key "sample_identifiers", "identifier_types", name: "sample_identifiers_identifier_type_fkey"
  add_foreign_key "selections", "projects", name: "selections_project_id_fkey"
  add_foreign_key "selections", "users", name: "selections_user_id_fkey"
  add_foreign_key "shares", "projects", name: "shares_project_id_fkey"
  add_foreign_key "shares", "users", name: "shares_user_id_fkey"
  add_foreign_key "std_methods", "docker_images", name: "std_methods_docker_image_id_fkey"
  add_foreign_key "std_methods", "speeds", name: "std_methods_speed_id_fkey"
  add_foreign_key "std_methods", "steps", name: "std_methods_step_id_fkey"
  add_foreign_key "std_methods", "versions", name: "std_methods_version_id_fkey"
  add_foreign_key "std_runs", "jobs", name: "std_runs_job_id_fkey"
  add_foreign_key "std_runs", "projects", name: "std_runs_project_id_fkey"
  add_foreign_key "std_runs", "statuses", name: "std_runs_status_id_fkey"
  add_foreign_key "std_runs", "std_methods", name: "std_runs_std_method_id_fkey"
  add_foreign_key "std_runs", "steps", name: "std_runs_step_id_fkey"
  add_foreign_key "std_runs", "users", name: "std_runs_user_id_fkey"
  add_foreign_key "steps", "docker_images", name: "steps_docker_image_id_fkey"
  add_foreign_key "steps", "versions", name: "steps_version_id_fkey"
  add_foreign_key "tmp_genes", "organisms_bkp", column: "organism_id", name: "tmp_genes_organism_id_fkey"
  add_foreign_key "todo_votes", "todos", name: "todo_votes_todo_id_fkey"
  add_foreign_key "todo_votes", "users", name: "todo_votes_user_id_fkey"
  add_foreign_key "todos", "statuses", name: "todos_status_id_fkey"
  add_foreign_key "todos", "todo_types", name: "todos_todo_type_id_fkey"
  add_foreign_key "todos", "users", name: "todos_user_id_fkey"
  add_foreign_key "tools", "tool_types", name: "tools_tool_type_id_fkey"
  add_foreign_key "trajectories", "jobs", name: "trajectories_job_id_fkey"
  add_foreign_key "trajectories", "projects", name: "trajectories_project_id_fkey"
  add_foreign_key "trajectories", "statuses", name: "trajectories_status_id_fkey"
  add_foreign_key "trajectories", "users", name: "trajectories_user_id_fkey"
  add_foreign_key "uploads", "projects", name: "uploads_project_id_fkey"
  add_foreign_key "users", "orcid_users", name: "users_orcid_user_id_fkey"
  add_foreign_key "versions", "steps", name: "versions_step_id_fkey"
  add_foreign_key "versions", "tool_types", name: "versions_tool_type_id_fkey"
end
