class ProjectType < ApplicationRecord
  has_many :projects

  validates :name, presence: true

  # Tags that share the single-cell (sc) analysis method allow-lists for
  # core pipeline steps (parsing, metadata, DE, clustering, heatmap,
  # module score, gene enrichment, umap, tsne, pca_sc) and the scFAIR
  # compliance schema.
  SC_LIKE_TAGS = %w[sc spat atac multi].freeze

  CANONICAL = {
    'sc' => {
      name: 'Single-cell (or nucleus) transcriptomics',
      row_label: 'genes',
      col_label: 'cells',
      admin_report_only: false
    },
    'bulk' => {
      name: 'Bulk transcriptomics',
      row_label: 'genes',
      col_label: 'samples',
      admin_report_only: false
    },
    'spat' => {
      name: 'Spatial transcriptomics',
      row_label: 'genes',
      col_label: 'cells',
      admin_report_only: true
    },
    'atac' => {
      name: 'ATAC-seq',
      row_label: 'genes',
      col_label: 'cells',
      admin_report_only: true
    },
    'multi' => {
      name: 'Multiomics',
      row_label: 'genes',
      col_label: 'cells',
      admin_report_only: true
    }
  }.freeze

  class << self
    def ensure_for_tag!(tag)
      key = tag.to_s
      attrs = CANONICAL[key]
      return find_by(tag: key) unless attrs

      record = find_or_initialize_by(tag: key)
      assign_attrs = attrs
      assign_attrs = attrs.except(:admin_report_only) unless record.new_record?
      record.assign_attributes(assign_attrs)
      record.save! if record.new_record? || record.changed?
      record
    end

    def selectable_for(include_restricted:)
      relation = order(:name)
      return relation if include_restricted

      relation.where(admin_report_only: false)
    end

    def project_visibility_counts_for(types)
      ids = types.map(&:id)
      counts = ids.each_with_object({}) { |id, hash| hash[id] = { public: 0, private: 0 } }
      return counts if ids.empty?

      Project.where(project_type_id: ids).group(:project_type_id, :public).count.each do |(type_id, is_public), n|
        key = is_public == true ? :public : :private
        counts[type_id][key] += n
      end
      counts
    end
  end

  def display_name
    name
  end

  def sc_like?
    SC_LIKE_TAGS.include?(tag.to_s)
  end
end
