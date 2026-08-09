# frozen_string_literal: true

module ExternalCatalog
  # Maps provider accessions to ASAP IdentifierType ids and normalizes DOI/PMID values.
  module ReferenceIds
    # Matches IdentifierType rows in ASAP (see identifier_types table).
    KIND_TO_TYPE_ID = {
      'geo_sample' => 1,
      'sra_study' => 2,
      'sra_sample' => 3,
      'bioproject' => 4,
      'geo_series' => 5,
      'array_express' => 6,
      'biosample' => 7,
      'sra_experiment' => 8,
      'sra_run' => 9,
      'ega_study' => 10
    }.freeze

    HCA_NAMESPACE_TO_KIND = {
      'geo_series' => 'geo_series',
      'geo' => 'geo_series',
      'array_express' => 'array_express',
      'ega' => 'ega_study',
      'ega_study' => 'ega_study',
      'ega_dataset' => 'ega_study',
      'insdc_project' => nil, # infer from accession (SRP/ERP/…)
      'insdc_study' => nil,  # infer (PRJNA/…)
      'bioproject' => 'bioproject'
    }.freeze

    module_function

    def type_id_for_kind(kind)
      KIND_TO_TYPE_ID[kind.to_s]
    end

    def normalize_doi(value)
      s = value.to_s.strip
      return nil if s.blank?

      s = s.sub(%r{\Ahttps?://(dx\.)?doi\.org/}i, '')
      s = s.sub(/\Adoi:\s*/i, '')
      s.presence
    end

    def normalize_pmid(value)
      s = value.to_s.strip
      return nil if s.blank?

      s = s.sub(%r{\Ahttps?://(www\.)?ncbi\.nlm\.nih\.gov/pubmed/}i, '')
      s = s.sub(%r{\Ahttps?://pubmed\.ncbi\.nlm\.nih\.gov/}i, '')
      s = s.split(%r{[/?#]}).first.to_s
      s = s.gsub(/\D/, '')
      s.presence
    end

    def kind_for_accession(accession)
      acc = accession.to_s.strip
      case acc
      when /\AGSE\d+/i then 'geo_series'
      when /\AGSM\d+/i then 'geo_sample'
      when /\A(SRP|ERP|DRP)\d+/i then 'sra_study'
      when /\A(SRS|ERS|DRS)\d+/i then 'sra_sample'
      when /\A(SRX|ERX|DRX)\d+/i then 'sra_experiment'
      when /\A(SRR|ERR|DRR)\d+/i then 'sra_run'
      when /\APRJ[A-Z]{2}\d+/i then 'bioproject'
      when /\AE-[A-Z]+-\d+/i then 'array_express'
      when /\AEGA[SD]\d+/i then 'ega_study'
      when /\ASAM[EN]\d+/i then 'biosample'
      else
        nil
      end
    end

    def identifier_hash(kind:, value:)
      v = value.to_s.strip
      return nil if v.blank?

      k = kind.to_s.presence || kind_for_accession(v)
      return nil if k.blank?
      return nil unless type_id_for_kind(k)

      { kind: k, value: v }
    end

    def from_hca_accession(namespace:, accession:)
      acc = accession.to_s.strip
      return nil if acc.blank?

      kind = HCA_NAMESPACE_TO_KIND[namespace.to_s.downcase]
      kind = kind_for_accession(acc) if kind.nil?
      identifier_hash(kind: kind, value: acc)
    end

    def extract_doi_from_text(text)
      return nil if text.blank?

      if (m = text.to_s.match(%r{(?:doi\.org/|doi:\s*)(10\.\S+)}i))
        return normalize_doi(m[1].sub(/[.,;)\]]+\z/, ''))
      end
      if (m = text.to_s.match(/\b(10\.\d{4,9}\/[-._;()\/:A-Z0-9]+)\b/i))
        return normalize_doi(m[1].sub(/[.,;)\]]+\z/, ''))
      end

      nil
    end

    def extract_accession_from_text(text)
      text.to_s.scan(
        /\b(?:GSE\d+|GSM\d+|E-[A-Z]+-\d+|EGA[SD]\d+|PRJ[A-Z]{2}\d+|(?:SRP|ERP|DRP|SRS|ERS|DRS|SRX|ERX|DRX|SRR|ERR|DRR)\d+)\b/i
      )
    end
  end
end
