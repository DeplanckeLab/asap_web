# frozen_string_literal: true

# Upserts the ASAP release v8 Heatmap step and its StdMethod.
#
# The Heatmap step is a reproducible, server-side clustering job: it slices a
# genes x cells expression matrix (genes chosen from a gene set collection,
# cells chosen from categorical metadata), computes seeded hierarchical
# clustering on both axes, and writes an ordered matrix + dendrograms +
# annotation tracks. The step's result panel hosts an interactive regl viewer.
#
# The step is available to both single-cell and bulk projects (project_types
# left empty means "all project types"). Column-scale handling (individual
# cells vs group means) is controlled by the column_mode parameter.
module HeatmapV8StdMethods
  VERSION_ID = 8
  STEP_NAME = "heatmap"

  # Merged into step.command_json before the std_method command_json.
  STEP_COMMAND_JSON = {
    "host_name" => "localhost",
    "docker_image" => "asap_run",
    "async" => true
  }.freeze

  STEP_OUTPUT_JSON = {
    "expected_outputs" => {
      "output_json" => {
        "types" => ["json_file"],
        "filename" => "output.json",
        "never_empty" => true
      },
      "output_log" => {
        "types" => ["log_file"],
        "filename" => "output.log"
      },
      "exec_stdout" => {
        "types" => ["log_file"],
        "filename" => "exec.out"
      },
      "exec_stderr" => {
        "types" => ["log_file"],
        "filename" => "exec.err"
      }
    }
  }.freeze

  METHOD_ATTRS_JSON = {
    "input_matrix" => {
      "label" => "Input matrix",
      "description" => "Expression matrix to build the heatmap from (normalized/scaled values give the most readable heatmaps).",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["num_matrix", "int_matrix"]],
      "source_steps" => %w[parsing cell_filtering gene_filtering normalization scaling clustering dim_reduction],
      "req_data_structure" => "array",
      "constraints" => {},
      "min_nber_items" => 1,
      "max_nber_items" => 1
    },
    "cells_metadata" => {
      "label" => "Cells/samples metadata",
      "description" => "Categorical metadata used to pick which cells/samples appear as columns. Leave empty to use all cells.",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["col_mdata"], ["discrete_mdata"]],
      "dataset_field" => "output_dataset",
      "constraints" => { "in_loom" => ["input_matrix"] },
      "requires" => ["input_matrix"],
      "source_steps" => %w[import_metadata parsing cell_filtering gene_filtering clustering],
      "req_data_structure" => "array",
      "min_nber_items" => 0,
      "max_nber_items" => 1,
      "default" => nil
    },
    "cells_metadata_sel" => {
      "label" => "Category filter",
      "description" => "Optionally restrict columns to a single category of the chosen metadata. Leave on the default to keep all cells.",
      "widget" => "select",
      "requires" => ["cells_metadata"],
      "not_null" => false,
      "null_name" => "All categories",
      "list" => [],
      "default" => nil
    },
    "global_gene_set_collection_id" => {
      "label" => "Gene set collection",
      "description" => "Gene set collection (global reference or custom/local) providing the genes to display as rows.",
      "widget" => "select",
      "list" => [],
      "requires" => ["input_matrix"],
      "not_null" => true
    },
    "global_gene_set_item_id" => {
      "label" => "Gene set",
      "description" => "Gene set within the selected collection. Its genes become the heatmap rows.",
      "widget" => "input_gene_set_item",
      "requires" => ["global_gene_set_collection_id"],
      "not_null" => true
    },
    "column_mode" => {
      "label" => "Columns",
      "description" => "Show individual cells/samples (with a cap), or aggregate to per-group mean profiles.",
      "widget" => "select",
      "list" => [["Individual cells/samples", "cells"], ["Group means (by metadata)", "group"]],
      "default" => "cells",
      "not_null" => true
    },
    "group_metadata" => {
      "label" => "Grouping metadata",
      "description" => "Categorical metadata used to aggregate columns when the group-means mode is selected.",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["col_mdata"], ["discrete_mdata"]],
      "dataset_field" => "output_dataset",
      "constraints" => {
        "in_loom" => ["input_matrix"],
        "visible_if" => [{ "attr" => "column_mode", "equals" => "group" }],
        "required_if" => [{ "attr" => "column_mode", "equals" => "group" }]
      },
      "requires" => ["input_matrix"],
      "source_steps" => %w[import_metadata parsing cell_filtering gene_filtering clustering],
      "req_data_structure" => "array",
      "min_nber_items" => 0,
      "max_nber_items" => 1,
      "default" => nil
    },
    "value_transform" => {
      "label" => "Value transform",
      "description" => "Per-gene z-score highlights relative up/down-regulation. Log1p or raw values are also available.",
      "widget" => "select",
      "list" => [["Row z-score", "zscore"], ["Log1p", "log1p"], ["None (raw)", "none"]],
      "default" => "zscore",
      "not_null" => true
    },
    "max_cells" => {
      "label" => "Max cells (columns)",
      "description" => "When showing individual cells, cap the number of columns by seeded subsampling above this value.",
      "widget" => "textfield",
      "type" => "int",
      "default" => 5000,
      "min_val" => 10,
      "requires" => ["input_matrix"]
    },
    "seed" => {
      "label" => "Random seed",
      "description" => "Seed for deterministic subsampling (reproducibility).",
      "widget" => "textfield",
      "type" => "int",
      "default" => 42,
      "min_val" => 0
    },
    "cluster_rows" => {
      "label" => "Cluster rows (genes)",
      "widget" => "checkbox",
      "type" => "bool",
      "default" => true
    },
    "cluster_cols" => {
      "label" => "Cluster columns",
      "widget" => "checkbox",
      "type" => "bool",
      "default" => true
    },
    "linkage_method" => {
      "label" => "Linkage method",
      "widget" => "select",
      "list" => [["Ward", "ward"], ["Average", "average"], ["Complete", "complete"], ["Single", "single"]],
      "default" => "ward",
      "not_null" => true
    },
    "distance_metric" => {
      "label" => "Distance metric",
      "widget" => "select",
      "list" => [["Euclidean", "euclidean"], ["Correlation", "correlation"], ["Cosine", "cosine"]],
      "default" => "euclidean",
      "not_null" => true
    }
  }.freeze

  STD_METHOD_COMMAND_JSON = {
    "program" => "python3.12 heatmap.v8.py",
    "opts" => [
      { "opt" => "-f", "param_key" => "input_matrix_filename" },
      { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
      { "opt" => "-o", "param_key" => "output_dir" },
      { "opt" => "--config", "value" => "\#{output_dir}/heatmap_config.json" }
    ],
    "predict_params" => %w[nber_cols nber_rows std_method_name]
  }.freeze

  SHOW_VIEW_JSON = [
    {
      "horiz_elements" => [
        {
          "id" => "card-heatmap",
          "type" => "card",
          "class" => "h-100",
          "container_class" => "col-md-12"
        }
      ]
    },
    {
      "horiz_elements" => [
        {
          "id" => "card-params",
          "type" => "card",
          "class" => "h-100",
          "container_class" => "col-md-6"
        },
        {
          "id" => "card-downloads",
          "type" => "card",
          "class" => "h-100",
          "container_class" => "col-md-6"
        }
      ]
    },
    {
      "admin" => false,
      "horiz_elements" => [
        {
          "id" => "card-exec_stdout",
          "type" => "card",
          "class" => "h-100",
          "container_class" => "col-md-6",
          "output_name" => "exec_stdout",
          "title" => "Docker execution STDOUT",
          "partial" => "text_file_content",
          "admin" => true
        },
        {
          "id" => "card-exec_stderr",
          "type" => "card",
          "class" => "h-100",
          "container_class" => "col-md-6",
          "output_name" => "exec_stderr",
          "title" => "Docker execution STDERR",
          "partial" => "text_file_content",
          "admin" => true
        }
      ]
    }
  ].freeze

  ATTR_LAYOUT_JSON = [
    {
      "horiz_elements" => [
        {
          "type" => "card",
          "card-header" => "Input matrix",
          "container_class" => "col-md-4",
          "class" => "card h-100",
          "label_class" => "col-md-6",
          "attr_list" => %w[input_matrix cells_metadata cells_metadata_sel]
        },
        {
          "type" => "card",
          "card-header" => "Genes",
          "container_class" => "col-md-4",
          "class" => "card h-100",
          "label_class" => "col-md-6",
          "attr_list" => %w[global_gene_set_collection_id global_gene_set_item_id]
        },
        {
          "type" => "card",
          "card-header" => "Columns and clustering",
          "container_class" => "col-md-4",
          "class" => "card h-100",
          "label_class" => "col-md-6",
          "attr_list" => %w[column_mode group_metadata value_transform max_cells seed cluster_rows cluster_cols linkage_method distance_metric]
        }
      ]
    }
  ].freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise "No Speed row found" unless speed

      step = ensure_step!(version_id, docker_image)

      summary = { created: [], updated: [], unchanged: [] }

      defn = { name: "heatmap" }
      attrs = build_std_method_attrs(defn, step: step, docker_image: docker_image, speed: speed)
      record = StdMethod.find_by(name: defn[:name], step_id: step.id, version_id: version_id)

      if record.nil?
        StdMethod.create!(attrs)
        summary[:created] << defn[:name]
      elsif std_method_changed?(record, attrs)
        record.update!(attrs)
        summary[:updated] << defn[:name]
      else
        summary[:unchanged] << defn[:name]
      end

      summary
    end

    private

    def resolve_docker_image!(version_id, docker_image_id)
      return DockerImage.find(docker_image_id) if docker_image_id.present?

      version = Version.find_by(id: version_id)
      tag = version ? "v#{version_id}" : nil
      image = DockerImage.find_by(tag: tag) if tag.present?
      image ||= DockerImage.where(version_id: version_id).order(:id).first
      raise "No DockerImage found for version_id=#{version_id}" unless image

      image
    end

    def ensure_step!(version_id, docker_image)
      step = Step.find_or_initialize_by(name: STEP_NAME, version_id: version_id, docker_image_id: docker_image.id)

      if step.new_record?
        reference = reference_step(version_id, docker_image.id)
        step.rank = ((reference&.rank) || Step.where(version_id: version_id, docker_image_id: docker_image.id).maximum(:rank).to_i) + 1
        step.group_name = reference&.group_name
        step.color = reference&.color
      end

      step.label = "Heatmap"
      step.tag = "heatmap"
      step.description = "Interactive heatmap of gene expression across selected cells/samples, with reproducible " \
                         "server-side hierarchical clustering and collapsible dendrograms."
      step.multiple_runs = true
      step.is_std_step = true
      step.has_std_form = true
      step.has_std_view = true
      step.hidden = false
      step.admin = false
      step.method_attrs_json = JSON.pretty_generate(METHOD_ATTRS_JSON)
      step.command_json = JSON.pretty_generate(STEP_COMMAND_JSON)
      step.output_json = JSON.pretty_generate(STEP_OUTPUT_JSON)
      step.show_view_json = JSON.pretty_generate(SHOW_VIEW_JSON)
      step.attrs_json = { "project_types" => [] }.to_json
      step.save!
      step
    end

    def reference_step(version_id, docker_image_id)
      %w[de ge clustering].each do |name|
        s = Step.find_by(name: name, version_id: version_id, docker_image_id: docker_image_id)
        return s if s
      end
      nil
    end

    def build_std_method_attrs(defn, step:, docker_image:, speed:)
      {
        name: defn[:name],
        label: "Heatmap",
        short_label: "heatmap",
        description: "Genes x cells expression heatmap with seeded hierarchical clustering on both axes.",
        link: "",
        version_id: step.version_id,
        docker_image_id: docker_image.id,
        step_id: step.id,
        speed_id: speed.id,
        nber_cores: 1,
        obsolete: false,
        attrs_json: "{}",
        attr_layout_json: JSON.pretty_generate(ATTR_LAYOUT_JSON),
        obj_attrs_json: { project_types: [], handles_log: false }.to_json,
        command_json: JSON.pretty_generate(STD_METHOD_COMMAND_JSON),
        output_json: JSON.pretty_generate(STEP_OUTPUT_JSON)
      }
    end

    def std_method_changed?(record, attrs)
      %i[label description link speed_id command_json output_json attrs_json attr_layout_json obj_attrs_json
         short_label obsolete].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
