# frozen_string_literal: true

# Persisted annotation bookmark color/status for one metadata category
# (annot_id + cat_idx). Client-only "loading" is never stored.
class AnnotationStatus < ApplicationRecord
  STATUSES = %w[none markers_ready annotated consensus].freeze

  belongs_to :project
  belongs_to :annot
  belongs_to :cell_set, optional: true
  belongs_to :best_cla, class_name: 'Cla', optional: true
  belongs_to :markers_run, class_name: 'Run', optional: true

  validates :cat_idx, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :annot_id, uniqueness: { scope: :cat_idx }

  scope :for_annots, ->(annot_ids) { where(annot_id: annot_ids) }

  def self.index_by_annot_cat(annot_ids)
    for_annots(annot_ids).index_by { |row| [row.annot_id, row.cat_idx.to_i] }
  end
end
