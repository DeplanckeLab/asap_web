class ExpEntryIdentifier < ApplicationRecord
  belongs_to :identifier_type, optional: true
  belongs_to :exp_entry, optional: true

  scope :for_type, ->(identifier_type_id) { where(identifier_type_id: identifier_type_id) }
end

