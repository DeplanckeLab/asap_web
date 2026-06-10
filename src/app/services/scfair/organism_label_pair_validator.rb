# frozen_string_literal: true

module Scfair
  # Validates that uns organism and organism_ontology_term_id are a consistent pair,
  # using the ASAP organisms reference table (tax_id <-> NCBITaxon, name <-> label).
  class OrganismLabelPairValidator
    CHECK_FIELD = 'ontology.semantics.organism_ontology_term_id.label_pair'
    TERM_FIELD = 'organism_ontology_term_id'
    LABEL_FIELD = 'organism'

    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format.to_s
      @term_path = Rules.field_path(@format, :uns, TERM_FIELD)
      @label_path = @format == 'h5ad' ? 'uns/organism' : '/attrs/organism'
    end

    def call
      term_id, label = resolve_pair

      if term_id.blank? && label.blank?
        return {
          errors: [],
          valid_checks: [{
            field: CHECK_FIELD,
            status: 'skipped',
            message: 'Organism metadata not present'
          }]
        }
      end

      if term_id.blank?
        return failure("organism label is present but #{TERM_FIELD} is missing")
      end

      if label.blank?
        return failure("#{LABEL_FIELD} label is required when #{TERM_FIELD} is present")
      end

      tax_id = extract_tax_id(term_id)
      unless tax_id
        return failure("#{TERM_FIELD} must use NCBITaxon:tax_id format (found #{term_id.inspect})")
      end

      organism = Organism.find_by(tax_id: tax_id)
      unless organism
        return failure("#{term_id} is not a known organism in the ASAP organisms table")
      end

      expected_term = "NCBITaxon:#{organism.tax_id}"
      if term_id != expected_term
        return failure(
          "#{TERM_FIELD} must be #{expected_term} for #{organism.name} (found #{term_id})"
        )
      end

      unless label_matches?(label, organism)
        return failure(
          "#{LABEL_FIELD} must match the name for #{expected_term} (expected #{organism.name.inspect}, got #{label.inspect})"
        )
      end

      {
        errors: [],
        valid_checks: [{
          field: CHECK_FIELD,
          status: 'passed',
          message: "organism label matches #{expected_term} (#{organism.name})"
        }]
      }
    end

    private

    def resolve_pair
      pairs_key = "#{@term_path}#label_pairs"
      pair_entry = Array(@field_values[pairs_key] || @field_values[pairs_key.to_sym]).first.to_s.strip
      if pair_entry.present?
        term_id, label = pair_entry.split(' || ', 2).map { |part| part.to_s.strip }
        return [term_id.presence, label.presence]
      end

      [
        first_value(@term_path),
        first_value(@label_path)
      ]
    end

    def first_value(path)
      Array(@field_values[path] || @field_values[path.to_sym]).first.to_s.strip.presence
    end

    def extract_tax_id(term_id)
      match = term_id.to_s.match(/\ANCBITaxon:(\d+)\z/)
      return nil unless match

      match[1].to_i
    end

    def label_matches?(label, organism)
      organism.name.to_s.strip == label.to_s.strip
    end

    def failure(message)
      {
        errors: [{ field: CHECK_FIELD, message: message }],
        valid_checks: [{ field: CHECK_FIELD, status: 'failed', message: message }]
      }
    end
  end
end
