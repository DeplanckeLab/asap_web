# frozen_string_literal: true

# Upserts ASAP release v8 clustering StdMethods (clustering.v8.R, clustering.v8.py).
module ClusteringV8StdMethods
  VERSION_ID = 8
  STEP_NAME = "clustering"

  NBER_PCS_EXPRESSIONS = {
    "default_expression" => "min(50, #input_matrix.nber_rows|min)",
    "max_val_expression" => "min(#input_matrix.nber_rows|min, 200)"
  }.freeze

  SEURAT_NBER_DIMS_ATTR = {
    "description" => "Number of PCA dimensions to use as input (NULL in R = all available PCs).",
    "label" => "Number of PCs from PCA to use",
    "type" => "int",
    "min_val" => 2,
    "max_val" => 200,
    "widget" => "select",
    "not_null" => 1
  }.merge(NBER_PCS_EXPRESSIONS).freeze

  SCANPY_NBER_DIMS_ATTR = {
    "description" => "Number of PCA dimensions to use as input (NULL = all available PCs).",
    "label" => "Number of PCs from PCA to use",
    "type" => "int",
    "min_val" => 2,
    "max_val" => 200,
    "widget" => "select",
    "not_null" => 1
  }.merge(NBER_PCS_EXPRESSIONS).freeze

  SEURAT_ATTRS_JSON = {
    "input_matrix" => {
      "label" => "PCA matrix",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["col_mdata"], ["discrete_mdata", "numeric_mdata"]],
      "source_steps" => %w[import_metadata pca pca_sc],
      "combinatorial_runs" => true,
      "req_data_structure" => "array",
      "constraints" => {},
      "min_nber_items" => 1,
      "max_nber_items" => 1
    },
    "nber_dims" => SEURAT_NBER_DIMS_ATTR,
    "n_neighbors" => {
      "label" => "Number of neighbors",
      "description" => "Number of neighbors for the kNN graph (FindNeighbors).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "20",
      "min_val" => 2
    },
    "metric" => {
      "label" => "Distance metric",
      "description" => "Distance metric for FindNeighbors.",
      "widget" => "select",
      "default" => "cosine",
      "list" => [
        %w[Cosine cosine],
        %w[Euclidean euclidean],
        %w[Manhattan manhattan],
        %w[Pearson pearson]
      ]
    },
    "resolution" => {
      "description" => "Clustering resolution. Higher values yield more clusters (FindClusters).",
      "label" => "Resolution",
      "type" => "float",
      "default" => "0.5",
      "min_val" => 0,
      "widget" => "textfield"
    },
    "seed" => {
      "label" => "Random seed",
      "description" => "Random seed for FindClusters (seed.use).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "42",
      "min_val" => 0
    }
  }.freeze

  SCANPY_ATTRS_JSON = {
    "input_matrix" => {
      "label" => "PCA matrix",
      "widget" => "input_data",
      "valid_types" => [["dataset"], ["col_mdata"], ["discrete_mdata", "numeric_mdata"]],
      "source_steps" => %w[import_metadata pca pca_sc],
      "combinatorial_runs" => true,
      "req_data_structure" => "array",
      "constraints" => {},
      "min_nber_items" => 1,
      "max_nber_items" => 1
    },
    "nber_dims" => SCANPY_NBER_DIMS_ATTR,
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
      "description" => "Distance metric for sc.pp.neighbors.",
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
    "resolution" => {
      "description" => "Clustering resolution. Higher values yield more clusters.",
      "label" => "Resolution",
      "type" => "float",
      "default" => "0.5",
      "min_val" => 0,
      "widget" => "textfield"
    },
    "random_state" => {
      "label" => "Random seed",
      "description" => "Random seed for sc.tl.leiden / sc.tl.louvain.",
      "widget" => "textfield",
      "type" => "int",
      "default" => "42",
      "min_val" => 0
    }
  }.freeze

  SEURAT_DEFINITIONS = [
    {
      name: "seurat_louvain_mlr",
      label: "Louvain MLR [Seurat]",
      short_label: "louvain_mlr",
      cli_method: "louvain_mlr",
      description: "Identify cell clusters with Seurat FindNeighbors and FindClusters using the " \
                   "Louvain algorithm with multilevel refinement (algorithm = 2)."
    },
    {
      name: "seurat_slm",
      label: "SLM [Seurat]",
      short_label: "slm",
      cli_method: "slm",
      description: "Identify cell clusters with Seurat FindNeighbors and FindClusters using the " \
                   "SLM (Smart Local Moving) algorithm (algorithm = 3)."
    },
    {
      name: "seurat_leiden",
      label: "Leiden [Seurat]",
      short_label: "leiden",
      cli_method: "leiden",
      description: "Identify cell clusters with Seurat FindNeighbors and FindClusters using the " \
                   "Leiden algorithm (algorithm = 4, default in Seurat v5)."
    }
  ].freeze

  SCANPY_DEFINITIONS = [
    {
      name: "scanpy_leiden",
      label: "Leiden [Scanpy]",
      short_label: "leiden",
      cli_method: "leiden",
      description: "Identify cell clusters with scanpy (sc.pp.neighbors + sc.tl.leiden) on PCA cell embeddings.",
      link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.tl.leiden.html">Reference</a>]'
    },
    {
      name: "scanpy_louvain",
      label: "Louvain [Scanpy]",
      short_label: "louvain",
      cli_method: "louvain",
      description: "Identify cell clusters with scanpy (sc.pp.neighbors + sc.tl.louvain) on PCA cell embeddings.",
      link: '[<a href="https://scanpy.readthedocs.io/en/stable/generated/scanpy.tl.louvain.html">Reference</a>]'
    }
  ].freeze

  LOUVAIN_REFERENCE = '[<a href="https://satijalab.org/seurat/reference/findclusters">Reference</a>]'

  class << self
    def upsert!(version_id: VERSION_ID, docker_image_id: nil)
      docker_image = resolve_docker_image!(version_id, docker_image_id)
      step = Step.find_by!(name: STEP_NAME, version_id: version_id, docker_image_id: docker_image.id)
      speed = Speed.find_by(id: 1) || Speed.first
      raise "No Speed row found" unless speed

      summary = { created: [], updated: [], unchanged: [] }

      sync_louvain_template!(step: step, docker_image: docker_image, speed: speed, summary: summary)

      upsert_definitions!(SEURAT_DEFINITIONS, step: step, docker_image: docker_image, speed: speed,
                          version_id: version_id, summary: summary, backend: :seurat)
      upsert_definitions!(SCANPY_DEFINITIONS, step: step, docker_image: docker_image, speed: speed,
                          version_id: version_id, summary: summary, backend: :scanpy)
      obsolete_duplicate_scanpy_clustering_methods!(step, version_id)

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

    def obsolete_duplicate_scanpy_clustering_methods!(step, version_id)
      StdMethod.where(step_id: step.id, version_id: version_id, name: %w[leiden_scanpy louvain_scanpy], obsolete: false)
               .update_all(obsolete: true)
    end

    def upsert_definitions!(definitions, step:, docker_image:, speed:, version_id:, summary:, backend:)
      definitions.each do |defn|
        record = StdMethod.find_by(name: defn[:name], step_id: step.id, version_id: version_id)
        attrs = build_attrs(defn, step: step, docker_image: docker_image, speed: speed, backend: backend)

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
    end

    def sync_louvain_template!(step:, docker_image:, speed:, summary:)
      record = StdMethod.find_by(id: 350)
      return unless record && record.name == "seurat_louvain" && record.step_id == step.id

      attrs = build_attrs(
        {
          name: "seurat_louvain",
          label: record.label,
          short_label: "louvain",
          cli_method: "louvain",
          description: record.description,
          link: record.link.presence || LOUVAIN_REFERENCE
        },
        step: step,
        docker_image: docker_image,
        speed: speed,
        output_json: record.output_json,
        backend: :seurat
      )

      if std_method_changed?(record, attrs)
        record.update!(attrs)
        summary[:updated] << "seurat_louvain"
      else
        summary[:unchanged] << "seurat_louvain"
      end
    end

    def build_attrs(defn, step:, docker_image:, speed:, output_json: "{}", backend: :seurat)
      attrs_json = backend == :scanpy ? SCANPY_ATTRS_JSON : SEURAT_ATTRS_JSON
      layout_json = attr_layout_json_for(backend)
      cmd = backend == :scanpy ? command_json_scanpy_for(defn[:cli_method]) : command_json_seurat_for(defn[:cli_method])

      {
        name: defn[:name],
        label: defn[:label],
        short_label: defn[:short_label],
        description: defn[:description],
        link: defn[:link] || LOUVAIN_REFERENCE,
        version_id: step.version_id,
        docker_image_id: docker_image.id,
        step_id: step.id,
        speed_id: speed.id,
        nber_cores: 1,
        obsolete: false,
        attrs_json: JSON.pretty_generate(attrs_json),
        attr_layout_json: layout_json,
        obj_attrs_json: { project_types: ProjectType::SC_LIKE_TAGS }.to_json,
        command_json: JSON.pretty_generate(cmd),
        output_json: output_json
      }
    end

    def attr_layout_json_for(backend)
      seed_attr = backend == :scanpy ? "random_state" : "seed"
      layout = [
        {
          "horiz_elements" => [
            {
              "type" => "card",
              "card-header" => "Input matrix",
              "container_class" => "col-md-6",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => %w[input_matrix nber_dims]
            },
            {
              "type" => "card",
              "card-header" => "Clustering parameters",
              "container_class" => "col-md-6",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => %w[n_neighbors metric resolution] + [seed_attr]
            }
          ]
        }
      ]
      JSON.pretty_generate(layout)
    end

    def command_json_seurat_for(cli_method)
      {
        "program" => "Rscript --vanilla clustering.v8.R",
        "opts" => base_clustering_opts(cli_method) + [
          { "opt" => "--seed_use", "param_key" => "seed" }
        ],
        "predict_params" => %w[nber_cols nber_rows std_method_name]
      }
    end

    def command_json_scanpy_for(cli_method)
      {
        "program" => "python3.12 clustering.v8.py",
        "opts" => base_clustering_opts(cli_method) + [
          { "opt" => "--random_state", "param_key" => "random_state" }
        ],
        "predict_params" => %w[nber_cols nber_rows std_method_name]
      }
    end

    def base_clustering_opts(cli_method)
      [
        { "opt" => "-f", "param_key" => "input_matrix_filename" },
        { "opt" => "--input_meta", "param_key" => "input_matrix_dataset" },
        { "opt" => "--method", "value" => cli_method },
        {
          "opt" => "--output_meta",
          "param_key" => "output_matrix_dataset",
          "value" => "/col_attrs/_clust_\#{run_num}_\#{std_method_name}"
        },
        { "opt" => "-o", "param_key" => "output_dir" },
        { "opt" => "--n_dims", "param_key" => "nber_dims" },
        { "opt" => "--n_neighbors", "param_key" => "n_neighbors" },
        { "opt" => "--metric", "param_key" => "metric" },
        { "opt" => "--resolution", "param_key" => "resolution" }
      ]
    end

    def std_method_changed?(record, attrs)
      %i[label description link speed_id command_json attrs_json attr_layout_json obj_attrs_json
         short_label obsolete].any? do |key|
        record.public_send(key).to_s != attrs[key].to_s
      end
    end
  end
end
