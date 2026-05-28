# frozen_string_literal: true

# Updates ASAP release v8 Seurat t-SNE / UMAP StdMethods (tsne.v8.R, umap.v8.R).
module SeuratTsneUmapV8StdMethods
  VERSION_ID = 8

  NBER_PCS_ATTR = {
    "nber_pcs" => {
      "description" => "Number of PCA dimensions to use as input (omit in R to use all available PCs).",
      "label" => "Number of PCs from PCA to use",
      "type" => "int",
      "default" => 50,
      "min_val" => 2,
      "max_val" => 200,
      "widget" => "select",
      "not_null" => 1
    }
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

  SEED_USE_ATTR = {
    "seed_use" => {
      "label" => "Random seed",
      "description" => "Random seed (seed.use).",
      "widget" => "textfield",
      "type" => "int",
      "default" => "42",
      "min_val" => 0,
      "not_null" => true
    }
  }.freeze

  DEFINITIONS = [
    {
      id: 348,
      name: "tsne_seurat",
      short_label: "RunTSNE",
      label: "t-SNE [Seurat]",
      description: "t-SNE embedding with Seurat v5 RunTSNE on PCA cell embeddings.",
      link: '[<a href="https://satijalab.org/seurat/reference/runtsne">Reference</a>]',
      program: "Rscript --vanilla tsne.v8.R",
      output_meta: "/col_attrs/_tsne_\#{run_num}_\#{std_method_name}_\#{n_components}D",
      attrs: NBER_PCS_ATTR.merge(N_COMPONENTS_ATTR).merge(SEED_USE_ATTR).merge(
        "perplexity" => {
          "label" => "Perplexity",
          "description" => "t-SNE perplexity (RunTSNE).",
          "widget" => "textfield",
          "type" => "float",
          "default" => "30",
          "min_val" => 1,
          "not_null" => true
        }
      ),
      param_attr_list: %w[perplexity seed_use],
      extra_opts: [
        { "opt" => "--perplexity", "param_key" => "perplexity" }
      ]
    },
    {
      id: 349,
      name: "umap_seurat",
      short_label: "RunUMAP",
      label: "UMAP [Seurat]",
      description: "UMAP embedding with Seurat v5 FindNeighbors and RunUMAP on PCA cell embeddings.",
      link: '[<a href="https://satijalab.org/seurat/reference/runumap">Reference</a>]',
      program: "Rscript --vanilla umap.v8.R",
      output_meta: "/col_attrs/_umap_\#{run_num}_\#{std_method_name}_\#{n_components}D",
      attrs: NBER_PCS_ATTR.merge(N_COMPONENTS_ATTR).merge(SEED_USE_ATTR).merge(
        "n_neighbors" => {
          "label" => "Number of neighbors",
          "description" => "Number of neighbors for the kNN graph (FindNeighbors).",
          "widget" => "textfield",
          "type" => "int",
          "default" => "30",
          "min_val" => 2,
          "not_null" => true
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
          ],
          "not_null" => true
        },
        "min_dist" => {
          "label" => "Minimum distance",
          "description" => "Minimum distance between points (RunUMAP min.dist).",
          "widget" => "textfield",
          "type" => "float",
          "default" => "0.3",
          "min_val" => 0,
          "max_val" => 1,
          "not_null" => true
        }
      ),
      param_attr_list: %w[n_neighbors metric min_dist seed_use],
      extra_opts: [
        { "opt" => "--n_neighbors", "param_key" => "n_neighbors" },
        { "opt" => "--metric", "param_key" => "metric" },
        { "opt" => "--min_dist", "param_key" => "min_dist" }
      ]
    }
  ].freeze

  class << self
    def upsert!
      summary = { updated: [], unchanged: [] }

      DEFINITIONS.each do |defn|
        record = StdMethod.find(defn[:id])
        raise "StdMethod id=#{defn[:id]} (#{defn[:name]}) not found" unless record
        raise "Expected name #{defn[:name]}, got #{record.name}" unless record.name == defn[:name]

        attrs = build_attrs(defn, record: record)

        if std_method_changed?(record, attrs)
          record.update!(attrs)
          summary[:updated] << defn[:name]
        else
          summary[:unchanged] << defn[:name]
        end
      end

      summary
    end

    private

    def build_attrs(defn, record:)
      {
        label: defn[:label],
        short_label: defn[:short_label],
        description: defn[:description],
        link: defn[:link],
        attrs_json: JSON.pretty_generate(defn[:attrs]),
        attr_layout_json: attr_layout_json_for(defn),
        command_json: JSON.pretty_generate(command_json_for(defn)),
        output_json: record.output_json.presence || "{}"
      }
    end

    def attr_layout_json_for(defn)
      layout = [
        {
          "horiz_elements" => [
            {
              "type" => "card",
              "card-header" => "Input matrix",
              "container_class" => "col-md-12",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => %w[input_matrix nber_pcs n_components]
            },
            {
              "type" => "card",
              "card-header" => "#{defn[:short_label]} parameters",
              "container_class" => "col-md-12",
              "class" => "card h-100",
              "label_class" => "col-md-6",
              "attr_list" => defn[:param_attr_list]
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
        { "opt" => "--method", "param_key" => "std_method_short_label" },
        {
          "opt" => "--output_meta",
          "param_key" => "output_matrix_dataset",
          "value" => defn[:output_meta]
        },
        { "opt" => "-o", "param_key" => "output_dir" },
        { "opt" => "--n_dims", "param_key" => "nber_pcs" },
        { "opt" => "--n_components", "param_key" => "n_components" },
        { "opt" => "--seed_use", "param_key" => "seed_use" }
      ] + defn[:extra_opts]

      {
        "program" => defn[:program],
        "opts" => opts,
        "predict_params" => %w[nber_cols nber_rows std_method_name]
      }
    end

    def std_method_changed?(record, attrs)
      attrs.any? { |key, val| record.public_send(key).to_s != val.to_s }
    end
  end
end
