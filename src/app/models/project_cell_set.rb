class ProjectCellSet < ApplicationRecord
  has_many :cell_sets, dependent: :nullify
end


