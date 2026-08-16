class RemoteGene < Asap2RemoteRecord
  self.table_name = "genes"
  BATCH_ENSEMBL_ID_SIZE = 5_000

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

  # Returns { "ensmusg..." => { ensembl_id:, first_ensembl_release:, latest_ensembl_release: } }
  # keyed by lowercased ensembl_id for case-insensitive lookup.
  def self.find_release_windows_by_organism_and_ensembls(organism_id, ensembl_ids, version:)
    oid = organism_id.to_i
    return {} unless oid.positive?

    ids = Array(ensembl_ids).map { |value| value.to_s.strip }.reject(&:blank?).uniq
    return {} if ids.empty?

    by_downcase = {}
    with_remote(version) do
      ids.each_slice(BATCH_ENSEMBL_ID_SIZE) do |slice|
        where(organism_id: oid, ensembl_id: slice)
          .pluck(:ensembl_id, :first_ensembl_release, :latest_ensembl_release)
          .each do |ensembl_id, first_release, latest_release|
            by_downcase[ensembl_id.to_s.downcase] = {
              ensembl_id: ensembl_id,
              first_ensembl_release: first_release,
              latest_ensembl_release: latest_release
            }
          end

        missing = slice.reject { |ensembl_id| by_downcase.key?(ensembl_id.downcase) }
        next if missing.empty?

        where(organism_id: oid)
          .where('LOWER(ensembl_id) IN (?)', missing.map(&:downcase))
          .pluck(:ensembl_id, :first_ensembl_release, :latest_ensembl_release)
          .each do |ensembl_id, first_release, latest_release|
            by_downcase[ensembl_id.to_s.downcase] = {
              ensembl_id: ensembl_id,
              first_ensembl_release: first_release,
              latest_ensembl_release: latest_release
            }
          end
      end
    end
    by_downcase
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

  def self.find_by_ensembl_id_flexible(ensembl_id, version:)
    e = ensembl_id.to_s.strip.sub(/\.\d+\z/, '')
    return nil if e.blank?

    with_remote(version) do
      where('LOWER(ensembl_id) = ?', e.downcase).order(:id).first
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
