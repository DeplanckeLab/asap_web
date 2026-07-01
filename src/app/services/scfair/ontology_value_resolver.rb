# frozen_string_literal: true

require 'set'

module Scfair
  # Resolves metadata field values against ontology DB rules and enum lists.
  # Returns { path => { value => true | false | 'mappable' } }.
  class OntologyValueResolver
    def self.call(groups:, field_values:, format: 'loom')
      new(groups: groups, field_values: field_values, format: format).call
    end

    def initialize(groups:, field_values:, format: 'loom')
      @groups = Array(groups)
      @field_values = field_values || {}
      @format = format.to_s
      @allowed_specials = Rules.allowed_special_values(@format)
    end

    def call
      result = {}

      @groups.each do |g|
        valid_values = g[:term_valid_values]
        prefixes = g[:term_ontology_prefixes]

        if valid_values.present?
          resolve_enum_field!(result, g, valid_values)
          next
        end

        next if prefixes.blank?

        ontology_ids = CellOntology.where(tag: prefixes).pluck(:id)
        next if ontology_ids.empty?

        scope = CellOntologyTerm.where(original: true, cell_ontology_id: ontology_ids)
        free_text_set = free_text_for_group(g)

        resolve_term_path!(result, g, scope, free_text_set)
        resolve_label_path!(result, g, scope, free_text_set) if g[:label_path].present?
      end

      result
    end

    private

    def values_at(path)
      Array(@field_values[path] || @field_values[path.to_sym]).map(&:to_s).reject(&:blank?)
    end

    def free_text_for_group(g)
      set = Set.new
      term_path = g[:term_path]
      specials = @allowed_specials[term_path] || @allowed_specials[term_path.to_sym]
      set.merge(specials) if specials
      set
    end

    def resolve_enum_field!(result, g, valid_values)
      term_vals = values_at(g[:term_path])
      return if term_vals.empty?

      valid_set = valid_values.map(&:downcase).to_set
      result[g[:term_path]] = term_vals.index_with { |v| valid_set.include?(v.downcase) }
    end

    def resolve_term_path!(result, g, scope, free_text_set)
      term_vals = values_at(g[:term_path])
      return if term_vals.empty?

      all_sub_terms = Set.new
      term_vals.each { |v| v.split(' || ').each { |t| all_sub_terms << t.strip } }
      all_sub_terms.reject!(&:blank?)

      ontology_sub_terms = all_sub_terms.reject { |t| free_text_set.include?(t) }
      known_ids = ontology_sub_terms.any? ? scope.where(identifier: ontology_sub_terms.to_a).pluck(:identifier).to_set : Set.new
      known_ids.merge(free_text_set)

      result[g[:term_path]] = term_vals.index_with do |v|
        parts = v.split(' || ').map(&:strip).reject(&:blank?)
        parts.all? { |p| known_ids.include?(p) }
      end
    end

    def resolve_label_path!(result, g, scope, free_text_set)
      label_vals = values_at(g[:label_path])
      return if label_vals.empty?

      all_sub_names = Set.new
      label_vals.each { |v| v.split(' || ').each { |t| all_sub_names << t.strip } }
      all_sub_names.reject!(&:blank?)

      ontology_sub_names = all_sub_names.reject { |t| free_text_set.include?(t) }
      exact_names = Set.new(free_text_set)
      mappable_names = Set.new

      if ontology_sub_names.any?
        lower_map = {}
        ontology_sub_names.each { |n| lower_map[n.downcase] = n }
        scope.where('LOWER(cell_ontology_terms.name) IN (?)', lower_map.keys)
             .pluck('cell_ontology_terms.name').each { |n| exact_names << lower_map[n.downcase] if lower_map[n.downcase] }

        remaining = ontology_sub_names.reject { |n| exact_names.include?(n) }
        if remaining.any?
          space_map = {}
          remaining.select { |n| n.include?('_') }.each { |n| space_map[n.tr('_', ' ').downcase] = n }
          if space_map.any?
            scope.where('LOWER(cell_ontology_terms.name) IN (?)', space_map.keys)
                 .pluck('cell_ontology_terms.name').each { |n| mappable_names << space_map[n.downcase] if space_map[n.downcase] }
          end
        end
      end

      result[g[:label_path]] = label_vals.index_with do |v|
        parts = v.split(' || ').map(&:strip).reject(&:blank?)
        if parts.all? { |p| exact_names.include?(p) }
          true
        elsif parts.all? { |p| exact_names.include?(p) || mappable_names.include?(p) }
          'mappable'
        else
          false
        end
      end
    end
  end
end
