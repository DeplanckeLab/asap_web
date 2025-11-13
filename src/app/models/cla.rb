class Cla < ApplicationRecord
  self.table_name = 'clas'

  belongs_to :cell_set
  belongs_to :project, optional: true

  scope :active, -> { where(obsolete: [false, nil]) }

  def score
    (nber_agree || 0) - (nber_disagree || 0)
  end
end


