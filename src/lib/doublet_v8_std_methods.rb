# frozen_string_literal: true

# Upserts ASAP release v8 doublet calling StdMethods (DoubletFinder + Scrublet).
module DoubletV8StdMethods
  VERSION_ID = 8
  STEP_NAME = "doublet_calling"

  # Merged into step.command_json before std_method command_json (see ReqsController#create_runs).
  STEP_COMMAND_JSON = {
    "host_name" => "localhost",
    "docker_image" => "asap_run",
    "async" => true
  }.freeze

  METADATA_EXPECTED_OUTPUTS = {
    "output_score_meta" => {
      "types" => ["dataset", "mdata", "col_mdata", "numeric_mdata"],
      "filepath" => "\#{input_matrix_filename}",
      "dataset" => "/col_attrs/_\#{step_tag}_\#{std_method_name}_score_df",
      "never_empty" => true
    },
    "output_call_meta" => {
      "types" => ["dataset", "mdata", "col_mdata", "discrete_mdata"],
      "filepath" => "\#{input_matrix_filename}",
      "dataset" => "/col_attrs/_\#{step_tag}_\#{std_method_name}_call_df",
      "never_empty" => true
    }
  }.freeze

  STEP_OUTPUT_JSON = {
    "expected_outputs" => METADATA_EXPECTED_OUTPUTS.merge(
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
    )
  }.freeze

  STD_METHOD_OUTPUT_JSON = {
    "expected_outputs" => METADATA_EXPECTED_OUTPUTS
  }.freeze

  METHOD_ATTRS_JSON = {
    "input_matrix" => {
      "label" => "Input matrix",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["num_matrix", "int_matrix"]],
      "source_steps" => %w[parsing cell_filtering gene_filtering],
      "combinatorial_runs" => true,
      "req_data_structure" => "array",
      "constraints" => {},
      "min_nber_items" => 1
    }
  }.freeze

  SHARED_ATTRS_JSON = {
    "clustering_meta" => {
      "label" => "Cluster labels (homotypic adjustment)",
      "description" => "Optional cluster labels for DoubletFinder homotypic doublet adjustment.",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["mdata", "col_mdata"], ["discrete_mdata"]],
      "source_steps" => %w[clustering],
      "constraints" => { "in_loom" => ["input_matrix"] },
      "req_data_structure" => "array",
      "max_nber_items" => 1,
      "min_nber_items" => 0,
      "optional" => true,
      "default" => nil
    },
    "variable_features_dataset" => {
      "label" => "Variable features metadata",
      "description" => "Optional HVG metadata passed to --features (defaults to internal variable gene selection).",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["row_mdata"], ["discrete_mdata", "numeric_mdata"]],
      "dataset_field" => "output_dataset",
      "constraints" => { "in_loom" => ["input_matrix"] },
      "requires" => ["input_matrix"],
      "source_steps" => %w[import_metadata hvg],
      "req_data_structure" => "array",
      "min_nber_items" => 0,
      "max_nber_items" => 1,
      "optional" => true,
      "default" => nil
    }
  }.freeze

  DOUBLET_FINDER_ATTRS_JSON = {
    "pk" => {
      "description" => "Neighborhood size (pK) for DoubletFinder paramSweep / scoring.",
      "label" => "pK",
      "type" => "float",
      "default" => 0.09,
      "min_val" => 0,
      "max_val" => 1,
      "widget" => "textfield",
      "not_null" => true
    },
    "seed_use" => {
      "label" => "Random seed",
      "description" => "Random seed used by DoubletFinder (seed.use).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "42",
      "min_val" => 0,
      "not_null" => true
    },
    "n_features" => {
      "label" => "Number of variable genes",
      "description" => "Number of variable genes for internal PCA (n_features).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "2000",
      "min_val" => 1,
      "not_null" => true
    },
    "pN" => {
      "label" => "Artificial doublet proportion (pN)",
      "description" => "Proportion of artificial doublets for DoubletFinder (pN).",
      "widget" => "textfield",
      "type" => "float",
      "default" => "0.25",
      "min_val" => 0,
      "max_val" => 1,
      "not_null" => true
    },
    "doublet_rate" => {
      "label" => "Expected doublet rate",
      "description" => "Expected doublet rate as a fraction of cells. Leave empty to use the 10x auto-formula.",
      "widget" => "textfield",
      "type" => "float",
      "default" => "",
      "min_val" => 0,
      "max_val" => 1,
      "not_null" => false
    }
  }.freeze

  SCRUBLET_ATTRS_JSON = {
    "expected_doublet_rate" => {
      "label" => "Expected doublet rate",
      "description" => "Expected doublet rate passed to scrublet (expected_doublet_rate).",
      "widget" => "textfield",
      "type" => "float",
      "default" => "",
      "min_val" => 0,
      "max_val" => 1,
      "not_null" => false
    },
    "random_state" => {
      "label" => "Random seed",
      "description" => "Random seed for scrublet.",
      "widget" => "textfield",
      "type" => "int",
      "default" => "0",
      "min_val" => 0,
      "not_null" => true
    }
  }.freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(name: STEP_NAME, version_id: version_id, docker_image_id: docker_image.id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise "No Speed row found" unless speed

      ensure_step_method_attrs!(step)
      ensure_step_command_json!(step)
      ensure_step_output_json!(step)
      ensure_step_view_flags!(step)

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
          name: "doublet_finder",
          label: "DoubletFinder",
          description: "Doublet scoring and calling with DoubletFinder on raw counts.",
          link: '[<a href="https://github.com/chris-mcginnis-ucsf/DoubletFinder">Reference</a>]',
          backend: :doublet_finder,
          project_types: %w[sc]
        },
        {
          name: "scrublet",
          label: "Scrublet",
          description: "Doublet scoring and calling with scrublet on raw counts.",
          link: '[<a href="https://github.com/AllonKleinLab/scrublet">Reference</a>]',
          backend: :scrublet,
          project_types: %w[sc]
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

    def ensure_step_method_attrs!(step)
      desired = JSON.pretty_generate(METHOD_ATTRS_JSON)
      return if step.method_attrs_json.to_s == desired

      step.update!(method_attrs_json: desired)
    end

    def ensure_step_command_json!(step)
      desired = JSON.pretty_generate(STEP_COMMAND_JSON)
      return if step.command_json.to_s == desired

      step.update!(command_json: desired)
    end

    def ensure_step_output_json!(step)
      desired = JSON.pretty_generate(STEP_OUTPUT_JSON)
      return if step.output_json.to_s == desired

      step.update!(output_json: desired)
    end

    def ensure_step_view_flags!(step)
      updates = {}
      updates[:has_std_view] = false unless step.has_std_view == false
      step.update!(updates) if updates.any?
    end

    def build_attrs(defn, step:, docker_image:, speed:)
      backend = defn[:backend]
      attrs_json = case backend
                   when :doublet_finder
                     SHARED_ATTRS_JSON.merge(DOUBLET_FINDER_ATTRS_JSON)
                   when :scrublet
                     SHARED_ATTRS_JSON.merge(SCRUBLET_ATTRS_JSON)
                   else
                     raise ArgumentError, "Unknown backend: #{backend.inspect}"
                   end

      {
        name: defn[:name],
        label: defn[:label],
        short_label: defn[:name],
        description: defn[:description],
        link: defn[:link],
        version_id: step.version_id,
        docker_image_id: docker_image.id,
        step_id: step.id,
        speed_id: speed.id,
        nber_cores: 1,
        obsolete: false,
        attrs_json: JSON.pretty_generate(attrs_json),
        attr_layout_json: attr_layout_json_for(backend),
        obj_attrs_json: { project_types: defn[:project_types] }.to_json,
        command_json: JSON.pretty_generate(command_json_for(backend)),
        output_json: JSON.pretty_generate(STD_METHOD_OUTPUT_JSON)
      }
    end

    def attr_layout_json_for(backend)
      input_attrs = %w[input_matrix variable_features_dataset]
      input_attrs << "clustering_meta" if backend == :doublet_finder

      param_attrs = case backend
                    when :doublet_finder
                      %w[pk seed_use n_features pN doublet_rate]
                    when :scrublet
                      %w[expected_doublet_rate random_state]
                    end

      layout = [
        {
          "horiz_elements" => [
            {
              "type" => "card",
              "card-header" => "Input data",
              "container_class" => "col-md-6",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => input_attrs
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

    def command_json_for(backend)
      base_opts = [
        { "opt" => "-f", "param_key" => "input_matrix_filename" },
        { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
        {
          "opt" => "--features",
          "param_key" => "variable_features_dataset",
          "omit_when_null" => true
        },
        {
          "opt" => "--output_score_meta",
          "param_key" => "output_matrix_dataset",
          "value" => "/col_attrs/_\#{step_tag}_\#{std_method_name}_score_df"
        },
        {
          "opt" => "--output_call_meta",
          "param_key" => "output_matrix_dataset",
          "value" => "/col_attrs/_\#{step_tag}_\#{std_method_name}_call_df"
        },
        { "opt" => "-o", "param_key" => "output_dir" }
      ]

      case backend
      when :doublet_finder
        {
          "program" => "Rscript --vanilla doublet.scoring.v8.R",
          "opts" => base_opts + [
            { "opt" => "--method", "value" => "DoubletFinder" },
            {
              "opt" => "--clustering_meta",
              "param_key" => "clustering_meta_dataset",
              "omit_when_null" => true
            },
            { "opt" => "--pK", "param_key" => "pk" },
            { "opt" => "--seed_use", "param_key" => "seed_use" },
            { "opt" => "--n_features", "param_key" => "n_features" },
            { "opt" => "--pN", "param_key" => "pN" },
            { "opt" => "--doublet_rate", "param_key" => "doublet_rate", "omit_when_null" => true }
          ],
          "predict_params" => %w[nber_cols nber_rows std_method_name]
        }
      when :scrublet
        {
          "program" => "python doublet.scoring.v8.py",
          "opts" => base_opts + [
            { "opt" => "--method", "value" => "scrublet" },
            { "opt" => "--expected_doublet_rate", "param_key" => "expected_doublet_rate", "omit_when_null" => true },
            { "opt" => "--random_state", "param_key" => "random_state" }
          ],
          "predict_params" => %w[nber_cols nber_rows std_method_name]
        }
      end
    end

    def std_method_changed?(record, attrs)
      %i[label description link speed_id command_json output_json attrs_json attr_layout_json obj_attrs_json
         short_label obsolete].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
