class Tool < ApplicationRecord
  belongs_to :tool_type, optional: true
end

