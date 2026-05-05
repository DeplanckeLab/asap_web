class Cla < ApplicationRecord
  self.table_name = 'clas'

  belongs_to :annot, optional: true
  belongs_to :cell_set
  belongs_to :cla_source, optional: true
  belongs_to :user, optional: true
  belongs_to :project, optional: true
  has_many :cla_votes, dependent: :destroy

  scope :active, -> { where(obsolete: [false, nil]) }

  def score
    (nber_agree || 0) - (nber_disagree || 0)
  end

  def origin_label
    return nil unless cla_source

    cla_source.label.to_s.strip.presence || cla_source.name.to_s.strip.presence
  end
end


