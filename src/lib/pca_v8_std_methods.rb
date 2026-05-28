# frozen_string_literal: true

# Upserts ASAP release v8 Scanpy PCA StdMethod (pca.v8.py).
module PcaV8StdMethods
  VERSION_ID = 8
  STEP_NAME = "pca_sc"

  ATTRS_JSON = {
    "variable_features_dataset" => {
      "label" => "Variable features metadata",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["row_mdata"], ["discrete_mdata", "numeric_mdata"]],
      "default" => nil,
      "dataset_field" => "output_dataset",
      "constraints" => { "in_loom" => ["input_matrix"] },
      "requires" => ["input_matrix"],
      "source_steps" => %w[import_metadata hvg],
      "req_data_structure" => "array",
      "min_nber_items" => 1,
      "max_nber_items" => 1,
      "optional" => false
    },
    "nber_dims" => {
      "description" => "Number of PCs to compute. Usually, the more cells you have in your dataset, the more PCs you should use.",
      "label" => "Number of PCs",
      "type" => "int",
      "default" => 50,
      "min_val" => 2,
      "max_val" => 200,
      "widget" => "select",
      "not_null" => 1
    },
    "no_zero_center" => {
      "label" => "Disable zero-centering",
      "description" => "Pass --no_zero_center to sc.pp.pca (default is zero-centering enabled).",
      "widget" => "checkbox",
      "type" => "bool",
      "default" => false
    },
    "svd_solver" => {
      "label" => "SVD solver",
      "description" => "SVD solver passed to sc.pp.pca.",
      "widget" => "select",
      "default" => "arpack",
      "list" => [%w[arpack arpack], %w[randomized randomized], %w[auto auto]],
      "not_null" => true
    },
    "random_state" => {
      "label" => "Random seed",
      "description" => "Random seed for sc.pp.pca (random_state).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "0",
      "min_val" => 0,
      "not_null" => true
    },
    "chunked" => {
      "label" => "Process in chunks",
      "description" => "Memory-efficient chunked processing (--chunked).",
      "widget" => "checkbox",
      "type" => "bool",
      "default" => false
    },
    "chunk_size" => {
      "label" => "Chunk size",
      "description" => "Chunk size when chunked processing is enabled (only used with --chunked).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "",
      "min_val" => 1,
      "requires" => ["chunked"],
      "requires_message" => "Enable chunked processing to set chunk size."
    }
  }.freeze

  ATTR_LAYOUT_JSON = <<~JSON.strip
    [
    {
    "horiz_elements" :
    [
     {"type" : "card",
      "card-header" : "Input matrix",
      "container_class" : "col-md-12",
      "class" : "card h-100",
      "label_class" : "col-md-6",
      "attr_list" : ["input_matrix", "variable_features_dataset", "nber_dims"]
     },
     {"type" : "card",
      "card-header" : "PCA parameters",
      "container_class" : "col-md-12",
      "class" : "card h-100",
      "label_class" : "col-md-6",
      "attr_list" : ["no_zero_center", "svd_solver", "random_state", "chunked", "chunk_size"]
     }
    ]
    }
    ]
  JSON

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(name: STEP_NAME, version_id: version_id, docker_image_id: docker_image.id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise "No Speed row found" unless speed

      attrs = build_attrs(step: step, docker_image: docker_image, speed: speed)
      record = StdMethod.find_by(name: "pca", step_id: step.id, version_id: version_id)
      summary = { created: [], updated: [], unchanged: [] }

      if record.nil?
        StdMethod.create!(attrs)
        summary[:created] << "pca"
      elsif std_method_changed?(record, attrs)
        record.update!(attrs)
        summary[:updated] << "pca"
      else
        summary[:unchanged] << "pca"
      end

      summary
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

    def build_attrs(step:, docker_image:, speed:)
      {
        name: "pca",
        label: "PCA [Scanpy]",
        short_label: "pca",
        description: "Principal component analysis with scanpy (sc.pp.pca) on the selected expression matrix.",
        link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.pp.pca.html">Reference</a>]',
        version_id: step.version_id,
        docker_image_id: docker_image.id,
        step_id: step.id,
        speed_id: speed.id,
        nber_cores: 1,
        obsolete: false,
        attrs_json: JSON.pretty_generate(ATTRS_JSON),
        attr_layout_json: ATTR_LAYOUT_JSON,
        obj_attrs_json: { handles_log: false, project_types: %w[sc] }.to_json,
        command_json: JSON.pretty_generate(command_json),
        output_json: "{}"
      }
    end

    def command_json
      {
        "program" => "python3.12 pca.v8.py",
        "opts" => [
          { "opt" => "-f", "param_key" => "input_matrix_filename" },
          { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
          { "opt" => "--method", "value" => "pca" },
          { "opt" => "--features", "param_key" => "variable_features_dataset", "omit_when_null" => true },
          {
            "opt" => "--output_meta",
            "param_key" => "output_matrix_dataset",
            "value" => "/col_attrs/_pca_\#{run_num}_\#{std_method_name}_\#{nber_dims}D"
          },
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

    def std_method_changed?(record, attrs)
      %i[label description link speed_id command_json attrs_json attr_layout_json obj_attrs_json obsolete].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
