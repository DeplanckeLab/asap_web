# frozen_string_literal: true

# Upserts ASAP release v8 HVG StdMethod rows:
#   - R-based methods (vst, dispersion, mean.var.plot) using hvg.asap.3.R
#     with per-method CLI options exposed in attrs_json.
#   - Python-based methods (seurat, seurat_v3, cell_ranger) using hvg.v8.py.
module HvgV8StdMethods
  VERSION_ID = 8
  STEP_NAME = "hvg"

  INPUT_ONLY_LAYOUT = <<~JSON.strip
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

  R_BASE_ARGS = [
    { "param_key" => "input_matrix_filename" },
    { "param_key" => "raw_matrix_dataset", "value" => "/matrix" },
    { "param_key" => "input_matrix_dataset" },
    { "param_key" => "output_matrix_dataset", "value" => '/row_attrs/hvg_#{run_num}_#{std_method_name}' },
    { "param_key" => "output_dir" },
    { "param_key" => "std_method_name" }
  ].freeze

  PARAM_DEFS = {
    "n_top_genes" => {
      "label" => "Number of top genes",
      "widget" => "textfield",
      "description" => "Number of top variable genes to select",
      "default" => 2000,
      "min_val" => 1
    },
    "loess_span" => {
      "label" => "Loess span",
      "widget" => "textfield",
      "description" => "Span for loess smoothing (vst only)",
      "default" => "0.3"
    },
    "clip_max" => {
      "label" => "Clip max",
      "widget" => "textfield",
      "description" => "After standardization, values above this are clipped (vst only)",
      "default" => "Inf"
    },
    "mean_cutoff" => {
      "label" => "Mean cutoff",
      "widget" => "textfield",
      "description" => "Min and max mean expression cutoffs as 'min,max' (e.g. '0.1,8')",
      "default" => "0.1,8"
    },
    "dispersion_cutoff" => {
      "label" => "Dispersion cutoff",
      "widget" => "textfield",
      "description" => "Min and max dispersion cutoffs as 'min,max' (e.g. '1,Inf')",
      "default" => "1,Inf"
    },
    "num_bin" => {
      "label" => "Number of bins",
      "widget" => "textfield",
      "description" => "Number of bins for mean variability plot",
      "default" => 20,
      "min_val" => 1
    }
  }.freeze

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
      r_methods + python_methods
    end

    private

    def r_methods
      [
        {
          name: "vst",
          label: "vst [Seurat]",
          description: "Identifies features (Highly Variable Genes, or HVG) that are outliers on a 'mean variability plot'." \
                       "<br/><b>vst</b>: First, fits a line to the relationship of log(variance) and log(mean) using local polynomial regression (loess). " \
                       "Then standardizes the feature values using the observed mean and expected variance (given by the fitted line). " \
                       "Feature variance is then calculated on the standardized values after clipping to a maximum (see clip.max parameter).",
          link: '[<a href="https://satijalab.org/seurat/reference/findvariablefeatures">Reference</a>]',
          handles_log: false,
          project_types: %w[sc],
          r_params: %w[n_top_genes loess_span clip_max]
        },
        {
          name: "dispersion",
          label: "Dispersion [Seurat]",
          description: "Identifies features (Highly Variable Genes, or HVG) that are outliers on a 'mean variability plot'." \
                       "<br/><b>dispersion (disp)</b>: Selects the genes with the highest dispersion values.",
          link: '[<a href="https://satijalab.org/seurat/reference/findvariablefeatures">Reference</a>]',
          handles_log: false,
          project_types: %w[sc],
          r_params: %w[n_top_genes mean_cutoff dispersion_cutoff]
        },
        {
          name: "mvp",
          label: "Mean var. plot [Seurat]",
          description: "Identifies features (Highly Variable Genes, or HVG) that are outliers on a 'mean variability plot'." \
                       "<br/><b>mean.var.plot (mvp)</b>: First, uses a function to calculate average expression (mean.function) " \
                       "and dispersion (dispersion.function) for each feature. Next, divides features into num.bin (deafult 20) " \
                       "bins based on their average expression, and calculates z-scores for dispersion within each bin. " \
                       "The purpose of this is to identify variable features while controlling for the strong relationship " \
                       "between variability and average expression.",
          link: '[<a href="https://satijalab.org/seurat/reference/findvariablefeatures">Reference</a>]',
          handles_log: false,
          project_types: %w[sc],
          r_params: %w[n_top_genes mean_cutoff dispersion_cutoff num_bin]
        }
      ]
    end

    def python_methods
      [
        {
          name: "hvg_seurat",
          label: "Seurat [Scanpy]",
          description: "Scanpy highly_variable_genes with flavor='seurat'. " \
                       "Normalizes by mean and dispersion of each gene across cells, " \
                       "then bins genes by mean expression and selects those with the highest " \
                       "normalized dispersion in each bin.",
          link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.pp.highly_variable_genes.html">Reference</a>]',
          program: "python3.12 hvg.v8.py",
          cli_method: "seurat",
          output_attr: '/row_attrs/hvg_#{run_num}_#{std_method_name}',
          handles_log: false,
          project_types: %w[sc]
        },
        {
          name: "hvg_seurat_v3",
          label: "Seurat v3 [Scanpy]",
          description: "Scanpy highly_variable_genes with flavor='seurat_v3'. " \
                       "Uses variance-stabilizing transformation on raw count data " \
                       "to select highly variable genes.",
          link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.pp.highly_variable_genes.html">Reference</a>]',
          program: "python3.12 hvg.v8.py",
          cli_method: "seurat_v3",
          output_attr: '/row_attrs/hvg_#{run_num}_#{std_method_name}',
          handles_log: false,
          project_types: %w[sc]
        },
        {
          name: "hvg_cell_ranger",
          label: "Cell Ranger [Scanpy]",
          description: "Scanpy highly_variable_genes with flavor='cell_ranger'. " \
                       "Implements the Cell Ranger method for selecting highly variable genes " \
                       "based on normalized dispersion.",
          link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.pp.highly_variable_genes.html">Reference</a>]',
          program: "python3.12 hvg.v8.py",
          cli_method: "cell_ranger",
          output_attr: '/row_attrs/hvg_#{run_num}_#{std_method_name}',
          handles_log: false,
          project_types: %w[sc]
        }
      ]
    end

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
        attrs_json: attrs_json_for(defn).to_json,
        attr_layout_json: attr_layout_json_for(defn),
        obj_attrs_json: {
          handles_log: defn[:handles_log],
          project_types: defn[:project_types]
        }.to_json,
        command_json: command_json_for(defn).to_json,
        output_json: "{}"
      }
    end

    def attrs_json_for(defn)
      param_keys = defn[:r_params]
      return {} unless param_keys&.any?

      param_keys.each_with_object({}) { |k, h| h[k] = PARAM_DEFS.fetch(k) }
    end

    def attr_layout_json_for(defn)
      param_keys = defn[:r_params]
      return INPUT_ONLY_LAYOUT unless param_keys&.any?

      layout = [
        {
          "horiz_elements" => [
            {
              "type" => "card",
              "card-header" => "Input data",
              "container_class" => "col-md-12",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => ["input_matrix"]
            },
            {
              "type" => "card",
              "card-header" => "Parameters",
              "container_class" => "col-md-12",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => param_keys
            }
          ]
        }
      ]
      JSON.pretty_generate(layout)
    end

    def command_json_for(defn)
      if defn[:r_params]
        opts = defn[:r_params].map { |k| { "opt" => "--#{k}", "param_key" => k } }
        {
          "program" => "Rscript --vanilla hvg.asap.3.R",
          "args" => R_BASE_ARGS,
          "opts" => opts,
          "predict_params" => %w[nber_cols nber_rows std_method_name]
        }
      else
        {
          "program" => defn[:program],
          "opts" => [
            { "opt" => "-f", "param_key" => "input_matrix_filename" },
            { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
            { "opt" => "--method", "value" => defn[:cli_method] },
            {
              "opt" => "--output_meta",
              "param_key" => "output_matrix_dataset",
              "value" => defn[:output_attr]
            }
          ],
          "predict_params" => %w[nber_cols nber_rows std_method_name]
        }
      end
    end

    def std_method_changed?(record, attrs)
      %i[label description link speed_id command_json attrs_json attr_layout_json obj_attrs_json obsolete].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
