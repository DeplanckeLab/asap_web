# frozen_string_literal: true

module Scfair
  # Maps assay ontology terms / labels onto ASAP project type tags.
  # Priority: spat (Visium / spatial), then multi (10x multiome), then atac.
  module AssayProjectTypeHelper
    ATAC_ASSAY_ROOT = SchemaConstants::ATAC_ASSAY_ROOT
    MULTIOME_ASSAY = SchemaConstants::MULTIOME_ASSAY

    VISIUM_LABEL = /visium/i
    SLIDE_SEQ_LABEL = /slide[\s-]?seq/i
    MULTIOME_LABEL = /multiome|multi-ome|multiomics|multi-omics/i
    ATAC_LABEL = /atac/i

    module_function

    def tag_for(field_values:, format: nil, resolver: nil)
      values = stringify_keys(field_values)
      resolver ||= OntologyLineageResolver.new
      formats = format.present? ? [format.to_s] : %w[loom h5ad]

      formats.each do |fmt|
        tag = tag_for_format(values, fmt, resolver)
        return tag if tag.present?
      end

      tag_from_labels(values)
    end

    # CELLxGENE (and similar) catalog payloads store assays as
    # [{ ontology_term_id:, label: }, ...].
    def tag_for_catalog_assays(assays)
      terms, labels = catalog_assay_terms_and_labels(assays)
      return nil if terms.empty? && labels.empty?

      tag_for(
        field_values: {
          'obs/assay_ontology_term_id' => terms,
          'obs/assay' => labels
        },
        format: 'h5ad'
      )
    end

    # True when every assay ontology term is 10x multiome or scATAC-seq / ATAC
    # (including descendants). Mixed ATAC/multiome + other assays is false.
    def catalog_assays_atac_or_multiome_only?(assays, resolver: nil)
      terms, = catalog_assay_terms_and_labels(assays)
      return false if terms.empty?

      resolver ||= OntologyLineageResolver.new
      terms.all? { |term| atac_like_term?(term, resolver: resolver) }
    end

    def atac_like_term?(term, resolver: nil)
      t = term.to_s
      return false if t.blank?
      return true if t == MULTIOME_ASSAY || t == ATAC_ASSAY_ROOT

      (resolver || OntologyLineageResolver.new).descendant_of?(t, ATAC_ASSAY_ROOT)
    end

    def tag_for_format(field_values, format, resolver)
      return 'spat' if SpatialAssayHelper.spatial_enabled?(field_values, format, resolver: resolver)

      terms = SpatialAssayHelper.assay_terms(field_values, format)
      return 'multi' if multiome_assay?(terms)
      return 'atac' if atac_assay?(terms, field_values, format, resolver: resolver)

      nil
    end

    def multiome_assay?(terms)
      Array(terms).map(&:to_s).include?(MULTIOME_ASSAY)
    end

    def atac_assay?(terms, field_values, format, resolver:)
      terms = Array(terms).map(&:to_s)
      return true if terms.include?(ATAC_ASSAY_ROOT)
      return true if terms.any? { |term| term.present? && resolver.descendant_of?(term, ATAC_ASSAY_ROOT) }

      atac_attrs_present?(field_values, format)
    end

    def atac_attrs_present?(field_values, format)
      prefix = format.to_s == 'h5ad' ? 'uns/atac' : '/attrs/atac'
      field_values.keys.any? { |key| key == prefix || key.to_s.start_with?("#{prefix}/") }
    end

    def tag_from_labels(field_values)
      labels = assay_labels(field_values)
      return nil if labels.empty?

      joined = labels.join(' ')
      return 'spat' if joined.match?(VISIUM_LABEL) || joined.match?(SLIDE_SEQ_LABEL)
      return 'multi' if joined.match?(MULTIOME_LABEL)
      return 'atac' if joined.match?(ATAC_LABEL)

      nil
    end

    def assay_labels(field_values)
      %w[/col_attrs/assay obs/assay].flat_map do |key|
        Array(field_values[key]).flat_map { |v| v.to_s.split(' || ') }
      end.map(&:strip).reject(&:blank?).uniq
    end

    def stringify_keys(field_values)
      return {} unless field_values.is_a?(Hash)

      field_values.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    def catalog_assay_terms_and_labels(assays)
      terms = []
      labels = []
      Array(assays).each do |assay|
        next unless assay.is_a?(Hash)

        term = assay[:ontology_term_id].presence || assay['ontology_term_id'].presence
        label = assay[:label].presence || assay['label'].presence
        terms << term.to_s if term.present?
        labels << label.to_s if label.present?
      end
      [terms.uniq, labels.uniq]
    end
  end
end
