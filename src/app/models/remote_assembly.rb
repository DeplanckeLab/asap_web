# frozen_string_literal: true

class RemoteAssembly < Asap2RemoteRecord
  self.table_name = "assemblies"

  belongs_to :remote_organism, foreign_key: :organism_id, class_name: "RemoteOrganism", optional: true
end
