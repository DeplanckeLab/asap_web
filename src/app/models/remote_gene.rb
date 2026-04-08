class RemoteGene < Asap2RemoteRecord
  self.table_name = "genes"

  def self.find_by_remote_id(gene_id, version:)
    id_i = gene_id.to_i
    return nil unless id_i.positive?

    with_remote(version) do
      find_by(id: id_i)
    end
  end

  def self.find_by_organism_and_ensembl(organism_id, ensembl_id, version:)
    oid = organism_id.to_i
    return nil unless oid.positive?

    e = ensembl_id.to_s.strip
    return nil if e.blank?

    with_remote(version) do
      where(organism_id: oid).where("LOWER(ensembl_id) = ?", e.downcase).first
    end
  end

  def self.find_by_organism_and_symbol(organism_id, symbol, version:)
    oid = organism_id.to_i
    return nil unless oid.positive?

    s = symbol.to_s.strip
    return nil if s.blank?

    with_remote(version) do
      where(organism_id: oid).where("LOWER(name) = ?", s.downcase).first
    end
  end

  def self.find_by_ensembl_id(ensembl_id, version:)
    with_remote(version) do
      find_by(ensembl_id: ensembl_id)
    end
  end

  def self.find_by_gene_symbol(symbol, version:)
    s = symbol.to_s.strip
    return nil if s.blank?

    with_remote(version) do
      where("LOWER(name) = ?", s.downcase).first
    end
  end
end
