# frozen_string_literal: true

# Upserts ASAP release v8 Scanpy t-SNE and UMAP StdMethods (tsne.v8.py, umap.v8.py).
module TsneUmapV8StdMethods
  VERSION_ID = 8

  NBER_PCS_EXPRESSIONS = {
    "default_expression" => "min(50, #input_matrix.nber_rows|min)",
    "max_val_expression" => "min(#input_matrix.nber_rows|min, 200)"
  }.freeze

  SHARED_PCA_DIMS_ATTR = {
    "nber_pcs" => {
      "description" => "Number of PCA dimensions to use as input (NULL = all).",
      "label" => "Number of PCs from PCA to use",
      "type" => "int",
      "min_val" => 2,
      "max_val" => 200,
      "widget" => "select",
      "not_null" => 1
    }.merge(NBER_PCS_EXPRESSIONS)
  }.freeze

  N_COMPONENTS_ATTR = {
    "n_components" => {
      "description" => "Number of embedding dimensions to compute.",
      "label" => "Number of dimensions",
      "type" => "int",
      "default" => 2,
      "min_val" => 2,
      "max_val" => 10,
      "widget" => "select",
      "not_null" => 1
    }
  }.freeze

  DEFINITIONS = [
    {
      name: "scanpy",
      step_name: "tsne",
      label: "t-SNE [Scanpy]",
      short_label: "tsne",
      description: "t-SNE embedding with scanpy (sc.tl.tsne) on PCA cell embeddings.",
      link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.tl.tsne.html">Reference</a>]',
      program: "python3.12 tsne.v8.py",
      cli_method: "tsne",
      output_meta: "/col_attrs/_tsne_\#{run_num}_\#{std_method_name}_\#{n_components}D",
      attrs: SHARED_PCA_DIMS_ATTR.merge(N_COMPONENTS_ATTR).merge(
        "perplexity" => {
          "label" => "Perplexity",
          "description" => "t-SNE perplexity (sc.tl.tsne).",
          "widget" => "textfield",
          "type" => "float",
          "default" => "30",
          "min_val" => 1
        },
        "random_state" => {
          "label" => "Random seed",
          "description" => "Random seed for sc.tl.tsne.",
          "widget" => "textfield",
          "type" => "int",
          "default" => "0",
          "min_val" => 0
        },
        "learning_rate" => {
          "label" => "Learning rate",
          "description" => "Learning rate for t-SNE ('auto' or a positive number).",
          "widget" => "textfield",
          "type" => "text",
          "default" => "auto"
        }
      ),
      param_attr_list: %w[nber_pcs n_components perplexity random_state learning_rate],
      extra_opts: [
        { "opt" => "--perplexity", "param_key" => "perplexity" },
        { "opt" => "--learning_rate", "param_key" => "learning_rate" }
      ]
    },
    {
      name: "scanpy",
      step_name: "umap",
      label: "UMAP [Scanpy]",
      short_label: "umap",
      description: "UMAP embedding with scanpy (sc.pp.neighbors + sc.tl.umap) on PCA cell embeddings.",
      link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.tl.umap.html">Reference</a>]',
      program: "python3.12 umap.v8.py",
      cli_method: "umap",
      output_meta: "/col_attrs/_umap_\#{run_num}_\#{std_method_name}_\#{n_components}D",
      attrs: SHARED_PCA_DIMS_ATTR.merge(N_COMPONENTS_ATTR).merge(
        "n_neighbors" => {
          "label" => "Number of neighbors",
          "description" => "Number of neighbors for the kNN graph (sc.pp.neighbors).",
          "widget" => "textfield",
          "type" => "int",
          "default" => "15",
          "min_val" => 2
        },
        "metric" => {
          "label" => "Distance metric",
          "description" => "Distance metric for the kNN graph (sc.pp.neighbors).",
          "widget" => "select",
          "default" => "euclidean",
          "list" => [
            %w[Euclidean euclidean],
            %w[Cosine cosine],
            %w[Manhattan manhattan],
            %w[Correlation correlation],
            %w[Jaccard jaccard]
          ]
        },
        "min_dist" => {
          "label" => "Minimum distance",
          "description" => "Minimum distance parameter for UMAP (sc.tl.umap).",
          "widget" => "textfield",
          "type" => "float",
          "default" => "0.5",
          "min_val" => 0,
          "max_val" => 1
        },
        "random_state" => {
          "label" => "Random seed",
          "description" => "Random seed for UMAP.",
          "widget" => "textfield",
          "type" => "int",
          "default" => 42,
          "min_val" => 0
        }
      ),
      param_attr_list: %w[nber_pcs n_components n_neighbors metric min_dist random_state],
      extra_opts: [
        { "opt" => "--n_neighbors", "param_key" => "n_neighbors" },
        { "opt" => "--metric", "param_key" => "metric" },
        { "opt" => "--min_dist", "param_key" => "min_dist" }
      ]
    }
  ].freeze

  OBSOLETE_STD_METHOD_NAMES = {
    "tsne" => %w[tsne],
    "umap" => %w[umap]
  }.freeze

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise "No Speed row found" unless speed

      summary = { created: [], updated: [], unchanged: [] }

      DEFINITIONS.each do |defn|
        step = Step.find_by!(name: defn[:step_name], version_id: version_id, docker_image_id: docker_image.id)
        ensure_pca_sc_in_input_source_steps!(step)

        attrs = build_attrs(defn, step: step, docker_image: docker_image, speed: speed)
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

        obsolete_duplicate_std_methods!(step, version_id, defn[:step_name])
      end

      summary
    end

    private

    def obsolete_duplicate_std_methods!(step, version_id, step_name)
      obsolete_names = OBSOLETE_STD_METHOD_NAMES[step_name]
      return if obsolete_names.blank?

      StdMethod.where(step_id: step.id, version_id: version_id, name: obsolete_names, obsolete: false)
               .update_all(obsolete: true)
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

    def ensure_pca_sc_in_input_source_steps!(step)
      h = JSON.parse(step.method_attrs_json.presence || "{}")
      im = h["input_matrix"]
      return unless im.is_a?(Hash)

      source_steps = Array(im["source_steps"])
      return if source_steps.include?("pca_sc")

      im["source_steps"] = source_steps + ["pca_sc"]
      step.update!(method_attrs_json: JSON.pretty_generate(h))
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
        attrs_json: JSON.pretty_generate(defn[:attrs]),
        attr_layout_json: attr_layout_json_for(defn),
        obj_attrs_json: { handles_log: false, project_types: %w[sc] }.to_json,
        command_json: JSON.pretty_generate(command_json_for(defn)),
        output_json: "{}"
      }
    end

    def attr_layout_json_for(defn)
      layout = [
        {
          "horiz_elements" => [
            {
              "type" => "card",
              "card-header" => "Input matrix",
              "container_class" => "col-md-6",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => ["input_matrix", "nber_pcs", "n_components"]
            },
            {
              "type" => "card",
              "card-header" => "Parameters",
              "container_class" => "col-md-6",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => defn[:param_attr_list].reject { |a| %w[nber_pcs n_components].include?(a) }
            }
          ]
        }
      ]
      JSON.pretty_generate(layout)
    end

    def command_json_for(defn)
      opts = [
        { "opt" => "-f", "param_key" => "input_matrix_filename" },
        { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
        { "opt" => "--method", "value" => defn[:cli_method] },
        {
          "opt" => "--output_meta",
          "param_key" => "output_matrix_dataset",
          "value" => defn[:output_meta]
        },
        { "opt" => "-o", "param_key" => "output_dir" },
        { "opt" => "--n_dims", "param_key" => "nber_pcs" },
        { "opt" => "--n_components", "param_key" => "n_components" },
        { "opt" => "--random_state", "param_key" => "random_state" }
      ] + defn[:extra_opts]

      {
        "program" => defn[:program],
        "opts" => opts,
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
