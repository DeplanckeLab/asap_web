class AnnotCellSet < ApplicationRecord
  belongs_to :project
  belongs_to :cell_set
  belongs_to :annot
end


