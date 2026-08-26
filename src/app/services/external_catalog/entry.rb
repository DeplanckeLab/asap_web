# frozen_string_literal: true

module ExternalCatalog
  Entry = Struct.new(
    :source,
    :external_id,
    :title,
    :url,
    :tax_id,
    :organism_label,
    :filesize,
    :n_obs,
    :n_vars,
    :project_type_tag,
    :format_kind,
    :filename,
    :dois,
    :pmids,
    :identifiers,
    :source_page_url,
    :collection_id,
    :collection_title,
    :collection_description,
    keyword_init: true
  ) do
    def provider_name
      case source.to_s
      when 'cellxgene' then 'CELLxGENE'
      when 'bgee' then 'Bgee'
      when 'ebi_sc' then 'EBI single cell expression atlas'
      when 'hca' then 'Human Cell Atlas'
      when 'hubmap' then 'HuBMAP'
      when 'broad_scp' then 'Broad Single Cell Portal'
      when 'allen_abc' then 'Allen Brain Cell Atlas'
      when 'matkp' then 'MATKP'
      when 'geo' then 'GEO'
      else
        raise ArgumentError, "Unknown catalog source: #{source.inspect}"
      end
    end

    def provider_tag
      case source.to_s
      when 'cellxgene' then 'CELLxGENE'
      when 'bgee' then 'Bgee'
      when 'ebi_sc' then 'EBI_SC'
      when 'hca' then 'HCA'
      when 'hubmap' then 'HUBMAP'
      when 'broad_scp' then 'BROAD_SCP'
      when 'allen_abc' then 'ALLEN_ABC'
      when 'matkp' then 'MATKP'
      when 'geo' then 'GEO'
      else
        raise ArgumentError, "Unknown catalog source: #{source.inspect}"
      end
    end

    # ASAP Project#name. GEO / EBI SC / Broad SCP / HuBMAP / Allen ABC / MATKP
    # always include the accession in the title.
    def project_name(max_length: 200)
      base_title = title.to_s.strip
      name =
        if %w[geo ebi_sc broad_scp hubmap allen_abc matkp].include?(source.to_s)
          acc = external_id.to_s.strip
          raise ArgumentError, "#{source} entry missing external_id (accession)" if acc.blank?

          if base_title.match?(/\b#{Regexp.escape(acc)}\b/i)
            base_title
          elsif base_title.present?
            "#{acc}: #{base_title}"
          else
            acc
          end
        else
          base_title.presence || external_id.to_s
        end
      name.to_s.truncate(max_length)
    end

    def normalized_dois
      Array(dois).filter_map { |d| ReferenceIds.normalize_doi(d) }.uniq
    end

    def normalized_pmids
      Array(pmids).filter_map { |p| ReferenceIds.normalize_pmid(p) }.uniq
    end

    # Array of { kind:, value: } hashes.
    def normalized_identifiers
      Array(identifiers).filter_map do |raw|
        if raw.is_a?(Hash)
          ReferenceIds.identifier_hash(
            kind: raw[:kind] || raw['kind'],
            value: raw[:value] || raw['value'] || raw[:id] || raw['id']
          )
        else
          ReferenceIds.identifier_hash(kind: nil, value: raw)
        end
      end.uniq { |h| [h[:kind], h[:value].to_s.upcase] }
    end
  end
end
