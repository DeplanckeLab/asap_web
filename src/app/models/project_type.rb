class ProjectType < ApplicationRecord
  has_many :projects

  validates :name, presence: true

  # Tags that share the single-cell (sc) analysis method allow-lists for
  # core pipeline steps (parsing, metadata, DE, clustering, heatmap,
  # module score, gene enrichment, umap, tsne, pca_sc).
  SC_LIKE_TAGS = %w[sc spat atac multi].freeze

  CANONICAL = {
    'sc' => {
      name: 'Single-cell (or nucleus) transcriptomics',
      row_label: 'genes',
      col_label: 'cells'
    },
    'bulk' => {
      name: 'Bulk transcriptomics',
      row_label: 'genes',
      col_label: 'samples'
    },
    'spat' => {
      name: 'Spatial transcriptomics',
      row_label: 'genes',
      col_label: 'cells'
    },
    'atac' => {
      name: 'ATAC-seq',
      row_label: 'genes',
      col_label: 'cells'
    },
    'multi' => {
      name: 'Multiomics',
      row_label: 'genes',
      col_label: 'cells'
    }
  }.freeze

  class << self
    def ensure_for_tag!(tag)
      key = tag.to_s
      attrs = CANONICAL[key]
      return find_by(tag: key) unless attrs

      record = find_or_initialize_by(tag: key)
      record.assign_attributes(attrs)
      record.save! if record.new_record? || record.changed?
      record
    end
  end

  def display_name
    name
  end

  def sc_like?
    SC_LIKE_TAGS.include?(tag.to_s)
  end
end
