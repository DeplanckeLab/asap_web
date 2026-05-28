# frozen_string_literal: true

require 'set'

# Standalone ontology checker for uploaded files.
# Uses the same ontology term type configuration as project compliance,
# but reads values from an extracted field-values hash.
class StandaloneOntologyComplianceChecker
  def initialize(field_values:, format:, organism_term_id: nil)
    @field_values = field_values || {}
    @format = format
    @organism_term_id = organism_term_id.to_s
    @errors = []
    @warnings = []
    @valid_checks = []
  end

  def run
    co_id_to_tag = CellOntology.pluck(:id, :tag).to_h
    otts = OntologyTermType.compliance_field_groups.to_a
    return result if otts.empty?

    tax_id = extract_tax_id(@organism_term_id)
    ontologies = CellOntology.where(id: otts.flat_map(&:cell_ontology_ids_list).uniq).index_by(&:id)

    otts.each do |ott|
      fg = ott.to_field_group(co_id_to_tag)
      term_path = path_for_format(fg[:term_path])
      next if term_path.blank?

      values = @field_values[term_path]
      next if values.blank?

      if fg[:term_valid_values].present?
        validate_enum(term_path, fg[:term_valid_values], values)
        next
      end

      prefixes = fg[:term_ontology_prefixes] || []
      next if prefixes.empty?

      valid_co_ids = ott.cell_ontology_ids_list.select do |co_id|
        co = ontologies[co_id]
        next false unless co
        co.tax_ids.blank? || (tax_id.present? && co.tax_ids.to_s.split(',').map(&:strip).include?(tax_id))
      end
      next if valid_co_ids.empty?

      scope = CellOntologyTerm.where(original: true, cell_ontology_id: valid_co_ids)
      allowed = allowed_free_text_values(ott, term_path)

      all_terms = values.flat_map { |v| split_multi(v) }.reject(&:blank?).uniq
      ontology_terms = all_terms.reject { |t| allowed.include?(t) }
      existing = ontology_terms.any? ? scope.where(identifier: ontology_terms).pluck(:identifier).to_set : Set.new

      invalid = all_terms.select do |term|
        next false if allowed.include?(term)
        !existing.include?(term)
      end

      if invalid.any?
        @errors << {
          field: term_path,
          message: "Unknown ontology identifier(s) for uploaded file: #{invalid.first(5).join(', ')}#{invalid.size > 5 ? ', ...' : ''}"
        }
      else
        @valid_checks << {
          field: term_path,
          message: "All ontology identifiers in '#{term_path}' resolved in authorized ontologies"
        }
      end
    end

    result
  end

  private

  def result
    { errors: @errors, warnings: @warnings, valid_checks: @valid_checks }
  end

  def path_for_format(path)
    return nil if path.blank?
    return path if @format == 'loom'

    path.to_s.sub(%r{\A/col_attrs/}, 'obs/').sub(%r{\A/row_attrs/}, 'var/').sub(%r{\A/attrs/}, 'uns/')
  end

  def split_multi(value)
    value.to_s.split(' || ').map(&:strip)
  end

  def allowed_free_text_values(ott, term_path)
    set = Set.new
    schema_special = CxgLoomValidatorService::ALLOWED_SPECIAL_VALUES[term_path] rescue nil
    set.merge(schema_special) if schema_special
    set.merge(ott.free_text_entries.map { |e| e.is_a?(Hash) ? e['value'].to_s : e.to_s })
    set
  end

  def validate_enum(path, valid_values, values)
    valid = valid_values.map(&:downcase).to_set
    invalid = values.reject { |v| valid.include?(v.to_s.downcase) }
    if invalid.any?
      @errors << {
        field: path,
        message: "Invalid value(s): #{invalid.first(5).join(', ')}. Allowed: #{valid_values.join(', ')}"
      }
    else
      @valid_checks << { field: path, message: "All values are valid for '#{path}'" }
    end
  end

  def extract_tax_id(term)
    m = term.match(/NCBITaxon:(\d+)/)
    m ? m[1] : nil
  end
end

