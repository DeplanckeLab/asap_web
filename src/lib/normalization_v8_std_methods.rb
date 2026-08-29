# frozen_string_literal: true

# Upserts ASAP release v8 normalization StdMethod rows from the LogNormalize (seurat) template.
module NormalizationV8StdMethods
  VERSION_ID = 8
  OUTPUT_MATRIX_DATASET = "/layers/_norm_\#{run_num}_\#{std_method_name}".freeze

  ATTR_LAYOUT_JSON = <<~JSON.strip
    [
    {
    "horiz_elements" :
    [
     {"type" : "card",
      "card-header" : "Input data",
      "container_class" : "col-md-12",
      "class" : "card h-100",
      "label_class" : "col-md-6",
      "attr_list" : ["input_matrix"]
     }
    ]
    }
    ]
  JSON

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(name: "normalization", version_id: version_id, docker_image_id: docker_image.id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise "No Speed row found" unless speed

      summary = { created: [], updated: [], unchanged: [] }

      definitions.each do |defn|
        record = StdMethod.find_by(name: defn[:name], step_id: step.id, version_id: version_id)
        attrs = build_attrs(defn, step: step, docker_image: docker_image, speed: speed)

        if record.nil?
          StdMethod.create!(attrs)
          summary[:created] << defn[:name]
        elsif normalization_std_method_changed?(record, attrs)
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
          name: "seurat",
          label: "LogNormalize [Seurat]",
          description: "Default Seurat normalization with scale.factor = 10000. <br/>Feature counts for each cell are divided by the total counts for that cell and multiplied by the scale.factor. This is then natural-log transformed using log1p.",
          link: "[<a href=\"https://satijalab.org/seurat/reference/normalizedata\">Reference</a>]",
          program: "Rscript --vanilla normalization.v8.R",
          cli_method: "LogNormalize",
          handles_log: false,
          project_types: %w[sc]
        },
        {
          name: "seurat_rc",
          label: "RC [Seurat]",
          description: "Seurat relative counts (RC) normalization on the selected expression matrix.",
          link: "[<a href=\"https://satijalab.org/seurat/reference/normalizedata\">Reference</a>]",
          program: "Rscript --vanilla normalization.v8.R",
          cli_method: "RC",
          handles_log: false,
          project_types: %w[sc]
        },
        {
          name: "seurat_clr",
          label: "CLR [Seurat]",
          description: "Centered log-ratio (CLR) normalization using Seurat NormalizeData.",
          link: "[<a href=\"https://satijalab.org/seurat/reference/normalizedata\">Reference</a>]",
          program: "Rscript --vanilla normalization.v8.R",
          cli_method: "CLR",
          handles_log: true,
          project_types: %w[sc]
        },
        {
          name: "seurat_sct",
          label: "SCTransform [Seurat]",
          description: "Variance-stabilizing normalization with Seurat SCTransform (Pearson residuals).",
          link: "[<a href=\"https://satijalab.org/seurat/reference/sctransform\">Reference</a>]",
          program: "Rscript --vanilla normalization.v8.R",
          cli_method: "SCTransform",
          handles_log: true,
          project_types: %w[sc]
        },
        {
          name: "scanpy_normalize_total",
          label: "normalize_total + log1p [Scanpy]",
          description: "Library-size normalization with scanpy (normalize_total) followed by log1p on the selected expression matrix.",
          link: "[<a href=\"https://scanpy.readthedocs.io/en/stable/generated/scanpy.pp.normalize_total.html\">Reference</a>]",
          program: "python3.12 normalize.v8.py",
          cli_method: "normalize_total",
          handles_log: true,
          project_types: %w[sc],
          python_log: true
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
        short_label: "",
        description: defn[:description],
        link: defn[:link],
        version_id: step.version_id,
        docker_image_id: docker_image.id,
        step_id: step.id,
        speed_id: speed.id,
        nber_cores: 1,
        obsolete: false,
        attrs_json: "{}",
        attr_layout_json: ATTR_LAYOUT_JSON,
        obj_attrs_json: {
          handles_log: defn[:handles_log],
          project_types: defn[:project_types]
        }.to_json,
        command_json: command_json_for(defn).to_json,
        output_json: "{}"
      }
    end

    def command_json_for(defn)
      opts = [
        { "opt" => "-f", "param_key" => "input_matrix_filename" },
        { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
        { "opt" => "--method", "value" => defn[:cli_method] },
        {
          "opt" => "--output_meta",
          "param_key" => "output_matrix_dataset",
          "value" => OUTPUT_MATRIX_DATASET
        },
        { "opt" => "-o", "param_key" => "output_dir" }
      ]
      opts << { "opt" => "--log", "value" => "" } if defn[:python_log]

      {
        "program" => defn[:program],
        "opts" => opts,
        "predict_params" => %w[nber_cols nber_rows std_method_name]
      }
    end

    def normalization_std_method_changed?(record, attrs)
      %i[label description link speed_id command_json attr_layout_json obj_attrs_json obsolete].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
