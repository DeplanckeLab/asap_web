class SampleIdentifier < ApplicationRecord
  belongs_to :identifier_type, optional: true
  has_many :exp_entries_sample_identifiers, dependent: :destroy
  has_many :exp_entries, through: :exp_entries_sample_identifiers
end

