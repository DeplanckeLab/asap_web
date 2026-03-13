class Cla < ApplicationRecord
  self.table_name = 'clas'

  belongs_to :annot, optional: true
  belongs_to :cell_set
  belongs_to :user, optional: true
  belongs_to :project, optional: true
  has_many :cla_votes, dependent: :destroy

  scope :active, -> { where(obsolete: [false, nil]) }

  def score
    (nber_agree || 0) - (nber_disagree || 0)
  end
end


