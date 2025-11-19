class ExpEntriesSampleIdentifier < ApplicationRecord
  self.table_name = 'exp_entries_sample_identifiers'
  
  belongs_to :exp_entry
  belongs_to :sample_identifier
end

