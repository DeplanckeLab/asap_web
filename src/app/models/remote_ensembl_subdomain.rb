# frozen_string_literal: true

class RemoteEnsemblSubdomain < Asap2RemoteRecord
  self.table_name = "ensembl_subdomains"

  has_many :remote_organisms, foreign_key: :ensembl_subdomain_id, class_name: "RemoteOrganism"
end
