class CellSet < ApplicationRecord
  belongs_to :project_cell_set
  has_many :annot_cell_sets, dependent: :destroy
  has_many :clas, class_name: 'Cla', dependent: :nullify
end


