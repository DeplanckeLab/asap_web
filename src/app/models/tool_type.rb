class ToolType < ApplicationRecord
  has_many :tools, dependent: :nullify
end

