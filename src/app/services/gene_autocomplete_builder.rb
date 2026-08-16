# frozen_string_literal: true

# Builds visualization gene autocomplete payloads from loom row attrs, enriched with
# gene DB alt_names / obsolete_alt_names for ranked client-side search.
class GeneAutocompleteBuilder
  SCHEMA_VERSION = 2
  BATCH_SIZE = 5_000

  class << self
    def usable_cached_payload?(payload)
      payload.is_a?(Hash) &&
        payload['schema_version'].to_i >= SCHEMA_VERSION &&
        payload['search'].is_a?(Array) &&
        payload['aliases'].is_a?(Hash)
    end

    def build(gene_values:, accession_values:, stable_values:, organism_id:, db_version:)
      size = [
        Array(gene_values).length,
        Array(accession_values).length,
        Array(stable_values).length
      ].min

      autocomplete_list = []
      h_indexes = {}
      accessions = []

      size.times do |i|
        gene = gene_values[i].to_s.strip
        accession = accession_values[i].to_s.strip
        stable = stable_values[i].to_s.strip
        next if gene.blank? || accession.blank? || stable.blank?

        h_indexes[stable] = i
        autocomplete_list << "#{gene} #{accession} {#{stable}}"
        accessions << accession
      end

      {
        'schema_version' => SCHEMA_VERSION,
        'search' => autocomplete_list.sort,
        'h_indexes' => h_indexes,
        'aliases' => load_aliases(
          accessions: accessions,
          organism_id: organism_id,
          db_version: db_version
        )
      }
    end

    def load_aliases(accessions:, organism_id:, db_version:)
      oid = organism_id.to_i
      db = db_version.to_s.strip
      ids = Array(accessions).map { |v| v.to_s.strip }.reject(&:blank?).uniq
      return {} if oid <= 0 || db.blank? || ids.empty?

      aliases = {}
      RemoteGene.with_remote(db) do
        ids.each_slice(BATCH_SIZE) do |slice|
          RemoteGene.where(organism_id: oid, ensembl_id: slice)
                    .pluck(:ensembl_id, :alt_names, :obsolete_alt_names)
                    .each do |ensembl_id, alt_names, obsolete_alt_names|
            key = ensembl_id.to_s.strip
            next if key.blank?

            aliases[key] = {
              'alt' => alias_tokens(alt_names),
              'obsolete' => alias_tokens(obsolete_alt_names)
            }
          end

          missing = slice.reject { |ensembl_id| aliases.key?(ensembl_id) }
          next if missing.empty?

          RemoteGene.where(organism_id: oid)
                    .where('LOWER(ensembl_id) IN (?)', missing.map(&:downcase))
                    .pluck(:ensembl_id, :alt_names, :obsolete_alt_names)
                    .each do |ensembl_id, alt_names, obsolete_alt_names|
            key = ensembl_id.to_s.strip
            next if key.blank? || aliases.key?(key)

            aliases[key] = {
              'alt' => alias_tokens(alt_names),
              'obsolete' => alias_tokens(obsolete_alt_names)
            }
          end
        end
      end
      aliases
    end

    def alias_tokens(raw)
      return [] if raw.nil?

      if raw.is_a?(Array)
        return raw.flat_map { |item| alias_tokens(item) }.uniq
      end

      s = raw.to_s.strip
      return [] if s.blank?

      if s.start_with?('[') && s.end_with?(']')
        begin
          loaded = JSON.parse(s)
          return alias_tokens(loaded) if loaded.is_a?(Array)
        rescue JSON::ParserError
          # fall through to CSV splitting
        end
      end

      s = s[1..-2] if s.start_with?('{') && s.end_with?('}')

      s.split(/[,;|]/).map { |token| token.strip.gsub(/\A["']|["']\z/, '') }.reject(&:blank?).uniq
    end
  end
end
