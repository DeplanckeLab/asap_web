# frozen_string_literal: true

module AsapData
  # Cross-ontology parent links used when computing CellOntologyTerm lineages.
  # Collected Uberon (and similar) often map species stage roots via xref on the
  # Uberon side (UBERON:0000105 xref ZFS:0100000) rather than is_a on the species term.
  module OntologyLineageBridges
    module_function

    def normalize_identifier(raw)
      return nil if raw.nil?

      s = raw.to_s.strip
      s = s.sub(/\s*\{.*\}\s*$/, '')
      s = s.sub(/^efo:EFO_(\d+)$/i, 'EFO:\1')
      s = s.sub(/^obo:(\w+)_(\d+)$/i, '\1:\2')
      if (m = s.match(/^([a-z]+):([A-Za-z]+)_(\d+)$/))
        s = "#{m[2].upcase}:#{m[3]}"
      end
      s
    end

    def extract_identifiers_from_value(value, out = [])
      case value
      when Array
        value.each { |entry| extract_identifiers_from_value(entry, out) }
      when Hash
        value.each_value { |entry| extract_identifiers_from_value(entry, out) }
      else
        str = value.to_s
        return out if str.strip.empty?

        str.scan(/[A-Za-z][A-Za-z0-9_]*:[A-Za-z0-9_]+/).each do |match|
          out << normalize_identifier(match)
        end
      end
      out
    end

    def prefix_of(identifier)
      identifier.to_s.split(':', 2).first&.upcase
    end

    # Identifiers referenced from content that belong to a different ontology prefix.
    def cross_ontology_targets(cot_identifier, h_cot, sources: :bridge)
      src_prefix = prefix_of(cot_identifier)
      return [] if src_prefix.nil? || src_prefix.empty?

      candidates = []
      case sources
      when :xref
        candidates |= extract_identifiers_from_value(h_cot['xref'])
        candidates |= extract_identifiers_from_value(h_cot['equivalent_to'])
      else
        candidates |= extract_identifiers_from_value(h_cot['xref'])
        candidates |= extract_identifiers_from_value(h_cot['equivalent_to'])
        candidates |= extract_identifiers_from_value(h_cot['consider'])
        candidates |= extract_identifiers_from_value(h_cot['replaced_by'])
        candidates |= extract_identifiers_from_value(h_cot['def'])

        relationship_hash = h_cot['relationship'].is_a?(Hash) ? h_cot['relationship'] : {}
        relationship_hash.each do |rel, values|
          next if rel.to_s == 'part_of'

          candidates |= extract_identifiers_from_value(values)
        end
      end

      candidates
        .compact
        .uniq
        .select do |identifier|
          dst_prefix = prefix_of(identifier)
          !dst_prefix.nil? && !dst_prefix.empty? && dst_prefix != src_prefix
        end
    end

    # Outbound bridges: species root with no native parents and an xref/def citation
    # to Uberon (e.g. HsapDv:0000000 xref UBERON:0000105).
    def outbound_bridge_terms(cot_identifier, h_cot, known_identifiers, has_native_parent:)
      return [] if has_native_parent

      cross_ontology_targets(cot_identifier, h_cot, sources: :bridge).select { |identifier| known_identifiers.include?(identifier) }
    end

    # Reverse bridges: Uberon (or other) term xref'ing a species term makes that
    # Uberon term a parent of the species term (e.g. UBERON:0000105 xref ZFS:0100000).
    # Only explicit xref/equivalent_to are used so anatomy timing relations (ZFA
    # existence_starts_during ZFS:...) do not invert into spurious parents.
    def reverse_bridge_parent_for(cot_identifier, h_cot, known_identifiers)
      return [] unless known_identifiers.include?(cot_identifier)

      cross_ontology_targets(cot_identifier, h_cot, sources: :xref).select { |identifier| known_identifiers.include?(identifier) }
    end
  end
end
