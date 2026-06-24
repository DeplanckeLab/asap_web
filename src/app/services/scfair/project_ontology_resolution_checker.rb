# frozen_string_literal: true

require 'set'

module Scfair
  # Project-only ontology resolution: validates values against ASAP ontology DB
  # and produces field_resolutions for the compliance fix UI.
  class ProjectOntologyResolutionChecker
    def initialize(field_values:, project:, format: 'loom')
      @field_values = field_values || {}
      @project = project
      @format = format.to_s
      @allowed_specials = Rules.allowed_special_values(@format)
      @field_resolutions = {}
      @errors = []
      @warnings = []
      @valid_checks = []
    end

    def call
      return empty_result unless @project

      organism = @project.organism
      tax_id_str = organism&.tax_id&.to_s

      otts = OntologyTermType.where.not(field_group_id: [nil, '']).to_a
      return empty_result if otts.empty?

      co_id_to_tag = CellOntology.pluck(:id, :tag).to_h
      all_co_ids = otts.flat_map(&:cell_ontology_ids_list).uniq
      ontologies = CellOntology.where(id: all_co_ids).index_by(&:id)

      otts.each { |ott| check_ott!(ott, co_id_to_tag, ontologies, tax_id_str) }

      {
        field_resolutions: @field_resolutions,
        errors: @errors,
        warnings: @warnings,
        valid_checks: @valid_checks
      }
    end

    private

    def empty_result
      { field_resolutions: {}, errors: [], warnings: [], valid_checks: [] }
    end

    def values_at(path)
      Array(@field_values[path] || @field_values[path.to_sym]).map(&:to_s).reject(&:blank?)
    end

    def check_ott!(ott, co_id_to_tag, ontologies, tax_id_str)
      term_path = ott.term_path
      return if term_path.blank?

      label_path = ott.respond_to?(:label_path) ? ott.label_path : nil
      label_path = nil if label_path.blank?
      fg = ott.to_field_group(co_id_to_tag)
      label_path ||= fg[:label_path]

      valid_co_ids = ott.cell_ontology_ids_list.select do |co_id|
        co = ontologies[co_id]
        next false unless co

        co.tax_ids.blank? || (tax_id_str.present? && co.tax_ids.to_s.split(',').map(&:strip).include?(tax_id_str))
      end

      allowed_free_text = Set.new(ott.free_text_entries.map { |e| e.is_a?(Hash) ? e['value'].to_s : e.to_s })
      schema_specials = @allowed_specials[term_path] || @allowed_specials[term_path.to_sym]
      allowed_free_text.merge(schema_specials) if schema_specials

      valid_values = fg[:term_valid_values]
      if valid_values.present?
        check_enum_field!(term_path, valid_values)
        return
      end

      return if valid_co_ids.empty?

      scope = CellOntologyTerm.with_active_cell_ontology.where(original: true, cell_ontology_id: valid_co_ids)
      valid_tags = valid_co_ids.filter_map { |cid| ontologies[cid]&.tag }

      check_term_identifiers!(term_path, scope, allowed_free_text, valid_tags)
      check_label_names!(label_path, scope, allowed_free_text, valid_tags) if label_path.present?
    end

    def check_enum_field!(term_path, valid_values)
      unique_values = values_at(term_path)
      return if unique_values.empty?

      valid_set = valid_values.map(&:downcase).to_set
      resolution = unique_values.index_with { |v| valid_set.include?(v.downcase) }
      @field_resolutions[term_path] = resolution

      invalid = resolution.count { |_v, ok| ok == false }
      field_name = term_path.split('/').last
      if invalid.positive?
        @errors << {
          field: term_path,
          message: "#{invalid} of #{unique_values.size} #{unique_values.size == 1 ? 'value' : 'values'} in '#{field_name}' not valid (allowed: #{valid_values.join(', ')})"
        }
      else
        n = unique_values.size
        @valid_checks << {
          field: term_path,
          message: "#{n <= 2 ? 'The' : 'All'} #{n} #{n == 1 ? 'value' : 'values'} in '#{field_name}' #{n == 1 ? 'is' : 'are'} valid"
        }
      end
    end

    def check_term_identifiers!(term_path, scope, allowed_free_text, valid_tags)
      unique_values = values_at(term_path)
      return if unique_values.empty?

      all_terms = Set.new
      unique_values.each { |val| val.split(' || ').each { |t| all_terms << t.strip } }
      all_terms.reject!(&:blank?)

      ontology_terms = all_terms.reject { |t| allowed_free_text.include?(t) }
      existing_ids = ontology_terms.any? ? scope.where(identifier: ontology_terms.to_a).pluck(:identifier).to_set : Set.new
      known = existing_ids | allowed_free_text

      resolution = unique_values.index_with do |v|
        parts = v.split(' || ').map(&:strip).reject(&:blank?)
        parts.all? { |p| known.include?(p) }
      end
      @field_resolutions[term_path] = resolution

      unresolved_count = resolution.count { |_v, ok| ok == false }
      field_name = term_path.split('/').last
      if unresolved_count.positive?
        missing = ontology_terms.reject { |t| existing_ids.include?(t) }
        @errors << {
          field: term_path,
          message: "#{unresolved_count} of #{unique_values.size} #{field_name} #{unique_values.size == 1 ? 'identifier' : 'identifiers'} not found in authorised ontologies (#{valid_tags.join(', ')}): #{missing.first(5).join(', ')}#{missing.size > 5 ? ', ...' : ''}"
        }
      else
        n = unique_values.size
        @valid_checks << {
          field: term_path,
          message: "#{n <= 2 ? 'The' : 'All'} #{n} #{field_name} #{n == 1 ? 'identifier' : 'identifiers'} found in authorised ontologies"
        }
      end
    end

    def check_label_names!(label_path, scope, allowed_free_text, valid_tags)
      label_values = values_at(label_path)
      return if label_values.empty?

      all_names = Set.new
      label_values.each { |val| val.split(' || ').each { |t| all_names << t.strip } }
      all_names.reject!(&:blank?)

      ontology_names = all_names.reject { |t| allowed_free_text.include?(t) }
      exact_names = Set.new(allowed_free_text)
      mappable_names = Set.new

      if ontology_names.any?
        lower_map = {}
        ontology_names.each { |n| lower_map[n.downcase] = n }
        scope.where('LOWER(cell_ontology_terms.name) IN (?)', lower_map.keys)
             .pluck('cell_ontology_terms.name').each { |n| exact_names << lower_map[n.downcase] if lower_map[n.downcase] }

        remaining = ontology_names.reject { |n| exact_names.include?(n) }
        if remaining.any?
          space_map = {}
          remaining.select { |n| n.include?('_') }.each { |n| space_map[n.tr('_', ' ').downcase] = n }
          if space_map.any?
            scope.where('LOWER(cell_ontology_terms.name) IN (?)', space_map.keys)
                 .pluck('cell_ontology_terms.name').each { |n| mappable_names << space_map[n.downcase] if space_map[n.downcase] }
          end
        end
      end

      resolution = label_values.index_with do |v|
        parts = v.split(' || ').map(&:strip).reject(&:blank?)
        if parts.all? { |p| exact_names.include?(p) }
          true
        elsif parts.all? { |p| exact_names.include?(p) || mappable_names.include?(p) }
          'mappable'
        else
          false
        end
      end
      @field_resolutions[label_path] = resolution

      unresolved_count = resolution.count { |_v, ok| ok == false }
      mappable_count = resolution.count { |_v, ok| ok == 'mappable' }
      label_name = label_path.split('/').last

      if unresolved_count.positive?
        missing_names = ontology_names.reject { |t| exact_names.include?(t) || mappable_names.include?(t) }
        @errors << {
          field: label_path,
          message: "#{unresolved_count} of #{label_values.size} #{label_name} #{label_values.size == 1 ? 'name' : 'names'} not found in authorised ontologies (#{valid_tags.join(', ')}): #{missing_names.first(5).join(', ')}#{missing_names.size > 5 ? ', ...' : ''}"
        }
      end

      if mappable_count.positive?
        mappable_list = ontology_names.select { |t| mappable_names.include?(t) }
        @warnings << {
          field: label_path,
          message: "#{mappable_count} #{label_name} #{mappable_count == 1 ? 'name' : 'names'} can be auto-mapped to correct ontology #{mappable_count == 1 ? 'label' : 'labels'}: #{mappable_list.first(5).join(', ')}#{mappable_list.size > 5 ? ', ...' : ''}"
        }
      end

      if unresolved_count.zero? && mappable_count.zero?
        @valid_checks << {
          field: label_path,
          message: "#{label_values.size <= 2 ? 'The' : 'All'} #{label_values.size} #{label_name} #{label_values.size == 1 ? 'name' : 'names'} found in authorised ontologies"
        }
      elsif unresolved_count.zero? && mappable_count.positive?
        exact_count = label_values.size - mappable_count
        @valid_checks << {
          field: label_path,
          message: "#{exact_count} of #{label_values.size} #{label_name} #{label_values.size == 1 ? 'name' : 'names'} found in authorised ontologies"
        }
      end
    end
  end
end
