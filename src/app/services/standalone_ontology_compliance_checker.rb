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
    Scfair::OntologySemanticsValidator.new(field_values: @field_values, format: @format).call
  end

  private

  def result; { errors: @errors, warnings: @warnings, valid_checks: @valid_checks }; end

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
    schema_special = Scfair::Rules.allowed_special_values(@format)[term_path] rescue nil
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

