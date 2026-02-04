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

ActiveRecord::Schema[8.1].define(version: 2026_02_04_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bla", id: false, force: :cascade do |t|
    t.integer "a"
  end

  create_table "db_sets", id: :serial, force: :cascade do |t|
    t.text "label"
    t.text "tag"
    t.integer "tool_id"
  end

  create_table "ensembl_subdomains", id: :serial, force: :cascade do |t|
    t.integer "latest_ensembl_release"
    t.text "name"
    t.text "url"
  end

  create_table "gene_names", id: :serial, force: :cascade do |t|
    t.integer "gene_id"
    t.integer "organism_id"
    t.text "value"
  end

  create_table "gene_set_items", id: :serial, force: :cascade do |t|
    t.integer "asap_data_id"
    t.text "content"
    t.datetime "created_at", precision: nil
    t.integer "gene_set_id"
    t.text "identifier"
    t.text "name"
    t.datetime "updated_at", precision: nil
    t.index ["gene_set_id", "identifier"], name: "gene_set_id_identifier_gene_set_items"
    t.index ["gene_set_id", "name"], name: "gene_set_items_gene_set_id_name"
    t.index ["gene_set_id"], name: "gene_set_id_gene_set_items"
  end

  create_table "gene_sets", id: :serial, force: :cascade do |t|
    t.integer "asap_data_id"
    t.datetime "created_at", precision: nil
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
    t.index ["organism_id", "ref_id"], name: "organism_id_ref_id_gene_sets"
  end

  create_table "genes", id: :serial, force: :cascade do |t|
    t.text "alt_names"
    t.text "biotype"
    t.text "chr"
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "ensembl_id"
    t.text "function_description"
    t.integer "gene_length"
    t.integer "latest_ensembl_release"
    t.text "name"
    t.integer "ncbi_gene_id"
    t.text "obsolete_alt_names"
    t.integer "organism_id"
    t.integer "sum_exon_length"
    t.integer "sum_exon_length2"
    t.datetime "updated_at", precision: nil
    t.index "organism_id, lower(alt_names)", name: "organism_lc_alt_names_idx"
    t.index "organism_id, lower(ensembl_id)", name: "organism_lc_ensembl_id_idx"
    t.index "organism_id, lower(name)", name: "organism_lc_name_idx"
    t.index ["ensembl_id"], name: "ensembl_id_genes"
    t.index ["ensembl_id"], name: "genes_ensembl_id_idx"
    t.index ["name"], name: "genes_name_idx"
    t.index ["organism_id", "alt_names"], name: "organism_alt_names_idx"
    t.index ["organism_id", "ensembl_id"], name: "organism_ensembl_id_idx"
    t.index ["organism_id", "name"], name: "organism_gene_name_idx"
    t.index ["organism_id"], name: "organism_id_genes"
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

  create_table "statuses", id: :serial, force: :cascade do |t|
    t.text "active_color"
    t.text "color"
    t.text "icon_class"
    t.text "icon_spin"
    t.text "img_extension"
    t.text "inactive_color"
    t.text "label"
    t.text "name"
  end

  create_table "tool_types", id: :serial, force: :cascade do |t|
    t.text "name"
  end

  create_table "tools", id: :serial, force: :cascade do |t|
    t.datetime "created_at", precision: nil
    t.text "description"
    t.text "label"
    t.text "name"
    t.text "step_ids"
    t.text "tag"
    t.integer "tool_type_id"
    t.datetime "updated_at", precision: nil
  end

  add_foreign_key "gene_names", "genes", name: "gene_names_gene_id_fkey2"
  add_foreign_key "gene_names", "organisms", name: "gene_names_organism_id_fkey2"
  add_foreign_key "gene_set_items", "gene_sets", name: "gene_set_items_gene_set_id_fkey1"
  add_foreign_key "gene_sets", "organisms", name: "gene_sets_organism_id_fkey"
  add_foreign_key "genes", "organisms", name: "genes_organism_id_fkey2"
  add_foreign_key "organisms", "ensembl_subdomains", name: "organisms_ensembl_subdomain_id_fkey"
  add_foreign_key "tools", "tool_types", name: "tools_tool_type_id_fkey"
end
