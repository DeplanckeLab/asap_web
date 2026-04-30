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

ActiveRecord::Schema[8.1].define(version: 2026_04_30_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bla", id: false, force: :cascade do |t|
    t.integer "a"
  end

  create_table "compliance_mappings", id: false, force: :cascade do |t|
    t.string "action_type", null: false
    t.datetime "applied_at", null: false
    t.datetime "created_at", null: false
    t.string "field_group_id", null: false
    t.bigserial "id", null: false
    t.integer "project_id", null: false
    t.text "resolve_map_json"
    t.string "set_value"
    t.integer "source_annot_id"
    t.string "source_path"
    t.string "target_path", null: false
    t.datetime "updated_at", null: false
  end

  create_table "compliance_term_replacements", id: false, force: :cascade do |t|
    t.integer "cell_ontology_term_id"
    t.bigint "compliance_mapping_id", null: false
    t.datetime "created_at", null: false
    t.bigserial "id", null: false
    t.string "original_value", null: false
    t.string "replacement_identifier"
    t.string "replacement_name"
    t.datetime "updated_at", null: false
  end

  create_table "db_sets", id: false, force: :cascade do |t|
    t.serial "id", null: false
    t.text "label"
    t.text "tag"
    t.integer "tool_id"
  end

  create_table "ensembl_subdomains", id: false, force: :cascade do |t|
    t.serial "id", null: false
    t.integer "latest_ensembl_release"
    t.text "name"
    t.text "url"
  end

  create_table "gene_names", id: false, force: :cascade do |t|
    t.integer "gene_id"
    t.serial "id", null: false
    t.integer "organism_id"
    t.text "value"
  end

  create_table "gene_set_items", id: false, force: :cascade do |t|
    t.integer "asap_data_id"
    t.text "content"
    t.datetime "created_at", precision: nil
    t.integer "gene_set_id"
    t.serial "id", null: false
    t.text "identifier"
    t.text "name"
    t.datetime "updated_at", precision: nil
    t.index ["gene_set_id", "identifier"], name: "gene_set_id_identifier_gene_set_items"
    t.index ["gene_set_id", "name"], name: "gene_set_items_gene_set_id_name"
    t.index ["gene_set_id"], name: "gene_set_id_gene_set_items"
    t.index "gene_set_id, lower(coalesce(name, ''::text))", name: "idx_gene_set_items_gene_set_lower_name"
    t.index "lower(coalesce(name, ''::text)) gin_trgm_ops", name: "idx_gene_set_items_name_gin_trgm", using: :gin
  end

  create_table "gene_sets", id: false, force: :cascade do |t|
    t.integer "asap_data_id"
    t.datetime "created_at", precision: nil
    t.serial "id", null: false
    t.text "label"
    t.integer "latest_ensembl_release"
    t.integer "nb_items", default: 3
    t.boolean "obsolete", default: false
    t.integer "organism_id"
    t.text "original_filename"
    t.integer "project_id"
    t.integer "ref_id"
    t.integer "tool_id"
    t.datetime "updated_at", precision: nil
    t.integer "user_id"
  end

  create_table "genes", id: false, force: :cascade do |t|
    t.text "alt_names"
    t.text "biotype"
    t.text "chr"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "ensembl_id"
    t.text "function_description"
    t.integer "gene_length"
    t.serial "id", null: false
    t.integer "latest_ensembl_release"
    t.text "name"
    t.integer "ncbi_gene_id"
    t.text "obsolete_alt_names"
    t.integer "organism_id"
    t.integer "sum_exon_length"
    t.integer "sum_exon_length2"
    t.datetime "updated_at", precision: nil
  end

  create_table "organisms", id: false, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "ensembl_db_name"
    t.integer "ensembl_subdomain_id"
    t.text "genrep_key"
    t.text "go_short_name"
    t.serial "id", null: false
    t.integer "latest_ensembl_release"
    t.text "name"
    t.text "short_name"
    t.text "tag"
    t.integer "tax_id"
    t.datetime "updated_at", precision: nil
  end

  create_table "statuses", id: false, force: :cascade do |t|
    t.text "active_color"
    t.text "color"
    t.text "icon_class"
    t.text "icon_spin"
    t.serial "id", null: false
    t.text "img_extension"
    t.text "inactive_color"
    t.text "label"
    t.text "name"
  end

  create_table "tool_types", id: false, force: :cascade do |t|
    t.serial "id", null: false
    t.text "name"
  end

  create_table "tools", id: false, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "description"
    t.serial "id", null: false
    t.text "label"
    t.text "name"
    t.text "step_ids"
    t.text "tag"
    t.integer "tool_type_id"
    t.datetime "updated_at", precision: nil
  end
end
