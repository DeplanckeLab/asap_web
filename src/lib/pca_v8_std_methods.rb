# frozen_string_literal: true

# Upserts ASAP release v8 PCA StdMethods (aligned with asap_run_new scripts):
#   - Scanpy (pca)  -> python/pca.v8.py
#   - Seurat (seurat) -> R/pca.v8.R
module PcaV8StdMethods
  VERSION_ID = 8
  STEP_NAME = "pca_sc"

  OUTPUT_MATRIX_DATASET = "/col_attrs/_pca_\#{run_num}_\#{std_method_name}_\#{nber_dims}D".freeze

  SHARED_ATTRS_JSON = {
    "variable_features_dataset" => {
      "label" => "Variable features metadata",
      "description" => "LOOM /row_attrs/ dataset with 0/1 flags identifying which genes to use for PCA " \
                       "(e.g. /row_attrs/highly_variable). When omitted, all genes are used.",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["row_mdata"], ["discrete_mdata", "numeric_mdata"]],
      "default" => nil,
      "dataset_field" => "output_dataset",
      "constraints" => { "in_loom" => ["input_matrix"] },
      "requires" => ["input_matrix"],
      "source_steps" => %w[import_metadata hvg],
      "req_data_structure" => "array",
      "min_nber_items" => 0,
      "max_nber_items" => 1
    },
    "nber_dims" => {
      "description" => "Number of principal components to compute.",
      "label" => "Number of PCs",
      "type" => "int",
      "default" => 50,
      "min_val" => 2,
      "max_val" => 200,
      "widget" => "select",
      "not_null" => 1
    }
  }.freeze

  SCANPY_NBER_DIMS_ATTR = {
    "description" => "Number of PCs to compute. Usually, the more cells you have in your dataset, the more PCs you should use.",
    "label" => "Number of PCs",
    "type" => "int",
    "default" => 50,
    "min_val" => 2,
    "max_val" => 200,
    "widget" => "select",
    "not_null" => 1
  }.freeze

  SCANPY_ATTRS_JSON = {
    "variable_features_dataset" => {
      "label" => "Variable features metadata",
      "description" => "HVG metadata (defaults to all genes when omitted).",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["row_mdata"], ["discrete_mdata", "numeric_mdata"]],
      "default" => nil,
      "dataset_field" => "output_dataset",
      "constraints" => { "in_loom" => ["input_matrix"] },
      "requires" => ["input_matrix"],
      "source_steps" => %w[import_metadata hvg],
      "req_data_structure" => "array",
      "min_nber_items" => 0,
      "max_nber_items" => 1
    },
    "nber_dims" => SCANPY_NBER_DIMS_ATTR,
    "no_zero_center" => {
      "label" => "Disable zero-centering",
      "description" => "Disable zero-centering in sc.pp.pca (default is zero-centering enabled).",
      "widget" => "checkbox",
      "type" => "bool",
      "default" => false
    },
    "svd_solver" => {
      "label" => "SVD solver",
      "widget" => "select",
      "default" => "arpack",
      "list" => [%w[arpack arpack], %w[randomized randomized], %w[auto auto]],
      "not_null" => true
    },
    "random_state" => {
      "label" => "Random seed",
      "widget" => "textfield",
      "type" => "int",
      "default" => "42",
      "min_val" => 0
    },
    "chunked" => {
      "label" => "Process in chunks",
      "description" => "Memory-efficient chunked processing.",
      "widget" => "checkbox",
      "type" => "bool",
      "default" => false
    },
    "chunk_size" => {
      "label" => "Chunk size",
      "description" => "Chunk size when chunked processing is enabled.",
      "widget" => "textfield",
      "type" => "int",
      "default" => "",
      "min_val" => 1,
      "requires" => ["chunked"],
      "requires_message" => "Enable chunked processing to set chunk size."
    }
  }.freeze

  SEURAT_ATTRS_JSON = SHARED_ATTRS_JSON.merge(
    "weight_by_var" => {
      "label" => "Weight by variance",
      "description" => "Weight cell embeddings by variance (RunPCA weight.by.var).",
      "widget" => "checkbox",
      "type" => "bool",
      "default" => true
    },
    "seed_use" => {
      "label" => "Random seed",
      "description" => "Random seed for RunPCA (seed.use).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "42",
      "min_val" => 0
    }
  ).freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(name: STEP_NAME, version_id: version_id, docker_image_id: docker_image.id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise "No Speed row found" unless speed

      summary = { created: [], updated: [], unchanged: [] }

      definitions.each do |defn|
        record = StdMethod.find_by(name: defn[:name], step_id: step.id, version_id: version_id)
        attrs = build_attrs(defn, step: step, docker_image: docker_image, speed: speed)

        if record.nil?
          StdMethod.create!(attrs)
          summary[:created] << defn[:name]
        elsif std_method_changed?(record, attrs)
          record.update!(attrs)
          summary[:updated] << defn[:name]
        else
          summary[:unchanged] << defn[:name]
        end
      end

      summary
    end

    def definitions
      [
        {
          name: "pca",
          label: "PCA [Scanpy]",
          short_label: "pca",
          description: "Principal component analysis with scanpy (sc.pp.pca) on the selected matrix. " \
                       "Cell embeddings are appended to the LOOM and output.json is written.",
          link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.pp.pca.html">Reference</a>]',
          attrs_json: SCANPY_ATTRS_JSON,
          param_attrs: %w[nber_dims no_zero_center svd_solver random_state chunked chunk_size],
          command_json: scanpy_command_json
        },
        {
          name: "seurat",
          label: "RunPCA [Seurat]",
          short_label: "RunPCA",
          description: "Reads a LOOM file, runs Seurat v5 RunPCA on the selected scaled/normalized matrix, " \
                       "appends cell embeddings into the LOOM, and writes output.json.",
          link: '[<a href="https://satijalab.org/seurat/reference/runpca">Reference</a>]',
          attrs_json: SEURAT_ATTRS_JSON,
          param_attrs: %w[nber_dims weight_by_var seed_use],
          command_json: seurat_command_json
        }
      ]
    end

    private

    def resolve_docker_image!(version_id, docker_image_id)
      if docker_image_id.present?
        return DockerImage.find(docker_image_id)
      end

      version = Version.find_by(id: version_id)
      tag = version ? "v#{version_id}" : nil
      image = DockerImage.find_by(tag: tag) if tag.present?
      image ||= DockerImage.where(version_id: version_id).order(:id).first
      raise "No DockerImage found for version_id=#{version_id}" unless image

      image
    end

    def build_attrs(defn, step:, docker_image:, speed:)
      {
        name: defn[:name],
        label: defn[:label],
        short_label: defn[:short_label],
        description: defn[:description],
        link: defn[:link],
        version_id: step.version_id,
        docker_image_id: docker_image.id,
        step_id: step.id,
        speed_id: speed.id,
        nber_cores: 1,
        obsolete: false,
        attrs_json: JSON.pretty_generate(defn[:attrs_json]),
        attr_layout_json: attr_layout_json_for(defn[:param_attrs]),
        obj_attrs_json: { handles_log: false, project_types: %w[sc] }.to_json,
        command_json: JSON.pretty_generate(defn[:command_json]),
        output_json: "{}"
      }
    end

    def attr_layout_json_for(param_attrs)
      layout = [
        {
          "horiz_elements" => [
            {
              "type" => "card",
              "card-header" => "Input data",
              "container_class" => "col-md-6",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => %w[input_matrix variable_features_dataset]
            },
            {
              "type" => "card",
              "card-header" => "Parameters",
              "container_class" => "col-md-6",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => param_attrs
            }
          ]
        }
      ]
      JSON.pretty_generate(layout)
    end

    def scanpy_command_json
      {
        "program" => "python3.12 pca.v8.py",
        "opts" => [
          { "opt" => "-f", "param_key" => "input_matrix_filename" },
          { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
          { "opt" => "--method", "value" => "pca" },
          { "opt" => "--features", "param_key" => "variable_features_dataset", "omit_when_null" => true },
          { "opt" => "--output_meta", "param_key" => "output_matrix_dataset", "value" => OUTPUT_MATRIX_DATASET },
          { "opt" => "-o", "param_key" => "output_dir" },
          { "opt" => "--n_pcs", "param_key" => "nber_dims" },
          { "opt" => "--no_zero_center", "param_key" => "no_zero_center", "valueless_flag" => true },
          { "opt" => "--svd_solver", "param_key" => "svd_solver" },
          { "opt" => "--random_state", "param_key" => "random_state" },
          { "opt" => "--chunked", "param_key" => "chunked", "valueless_flag" => true },
          { "opt" => "--chunk_size", "param_key" => "chunk_size", "omit_when_null" => true }
        ],
        "predict_params" => %w[nber_cols nber_rows std_method_name]
      }
    end

    def seurat_command_json
      {
        "program" => "Rscript --vanilla pca.v8.R",
        "opts" => [
          { "opt" => "-f", "param_key" => "input_matrix_filename" },
          { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
          { "opt" => "--method", "value" => "RunPCA" },
          { "opt" => "--features", "param_key" => "variable_features_dataset", "omit_when_null" => true },
          { "opt" => "--output_meta", "param_key" => "output_matrix_dataset", "value" => OUTPUT_MATRIX_DATASET },
          { "opt" => "-o", "param_key" => "output_dir" },
          { "opt" => "--n_pcs", "param_key" => "nber_dims" },
          { "opt" => "--weight_by_var", "param_key" => "weight_by_var" },
          { "opt" => "--seed_use", "param_key" => "seed_use" }
        ],
        "predict_params" => %w[nber_cols nber_rows std_method_name]
      }
    end

    def std_method_changed?(record, attrs)
      %i[label description link speed_id command_json attrs_json attr_layout_json obj_attrs_json obsolete short_label].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
