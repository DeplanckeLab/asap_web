class ProjectType < ApplicationRecord
  has_many :projects

  validates :name, presence: true

  # Tags that share the single-cell (sc) analysis method allow-lists for
  # core pipeline steps (parsing, metadata, DE, clustering, heatmap,
  # module score, gene enrichment, umap, tsne, pca_sc).
  SC_LIKE_TAGS = %w[sc spat atac multi].freeze

  def display_name
    name
  end

  def sc_like?
    SC_LIKE_TAGS.include?(tag.to_s)
  end
end
