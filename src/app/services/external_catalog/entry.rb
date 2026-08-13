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
      when 'hca' then 'Human Cell Atlas'
      when 'geo' then 'GEO'
      else
        raise ArgumentError, "Unknown catalog source: #{source.inspect}"
      end
    end

    def provider_tag
      case source.to_s
      when 'cellxgene' then 'CELLxGENE'
      when 'bgee' then 'Bgee'
      when 'hca' then 'HCA'
      when 'geo' then 'GEO'
      else
        raise ArgumentError, "Unknown catalog source: #{source.inspect}"
      end
    end

    # ASAP Project#name. GEO always includes the GSE accession in the title.
    def project_name(max_length: 200)
      base_title = title.to_s.strip
      name =
        if source.to_s == 'geo'
          gse = external_id.to_s.strip
          raise ArgumentError, 'GEO entry missing external_id (GSE accession)' if gse.blank?

          if base_title.match?(/\b#{Regexp.escape(gse)}\b/i)
            base_title
          elsif base_title.present?
            "#{gse}: #{base_title}"
          else
            gse
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
