class AnnotCellSet < ApplicationRecord
  belongs_to :project, inverse_of: :annot_cell_sets
  belongs_to :cell_set
  belongs_to :annot
end


