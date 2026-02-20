class RemoteGene < Asap2RemoteRecord
  self.table_name = "genes"

  def self.find_by_ensembl_id(ensembl_id, version:)
    with_remote(version) do
      find_by(ensembl_id: ensembl_id)
    end
  end
end
