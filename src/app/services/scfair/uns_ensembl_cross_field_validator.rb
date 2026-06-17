# frozen_string_literal: true

module Scfair
  # Cross-field checks between uns Ensembl metadata and organism reference assemblies.
  class UnsEnsemblCrossFieldValidator
    CHECK_PREFIX = 'cross-field.uns_ensembl'

    def initialize(field_values:, format:, lookup: EnsemblReferenceLookup.new)
      @field_values = field_values || {}
      @format = format.to_s
      @lookup = lookup
    end

    def call
      errors = []
      valid_checks = []

      organism_term = first_uns_value('organism_ontology_term_id')
      release = parse_ensembl_release
      assembly = first_uns_value('ensembl_assembly')

      validate_release_organism(errors, valid_checks, organism_term, release)
      validate_assembly_organism_release(errors, valid_checks, organism_term, release, assembly)

      { errors: errors, valid_checks: valid_checks }
    end

    private

    def validate_release_organism(errors, valid_checks, organism_term, release)
      check_id = "#{CHECK_PREFIX}.release"
      if release.blank?
        record_skip(valid_checks, check_id, 'ensembl_release not set; cannot verify organism compatibility')
        return
      end

      tax_id = extract_tax_id(organism_term)
      if tax_id.blank?
        record_skip(valid_checks, check_id, 'organism_ontology_term_id missing or invalid')
        return
      end

      unless @lookup.remote_available?
        record_skip(valid_checks, check_id, 'ASAP reference assemblies unavailable')
        return
      end

      assemblies = @lookup.assemblies_for_tax_id(tax_id)
      if assemblies.empty?
        record_skip(valid_checks, check_id, 'No assemblies found in ASAP for this organism')
        return
      end

      if @lookup.release_supported_by_organism?(tax_id, release)
        record_pass(valid_checks, check_id, "ensembl_release #{release} is supported by at least one ASAP assembly for the organism")
        return
      end

      ranges = assemblies.map do |assembly|
        latest = assembly.latest_ensembl_release.presence || 'present'
        "#{assembly.name} (#{assembly.first_ensembl_release}-#{latest})"
      end.join(', ')
      message = "ensembl_release #{release} is not supported by any ASAP assembly for #{organism_term} (available: #{ranges})"
      record_failure(errors, valid_checks, check_id:, message:)
    end

    def validate_assembly_organism_release(errors, valid_checks, organism_term, release, assembly)
      check_id = "#{CHECK_PREFIX}.assembly"
      if assembly.blank?
        record_skip(valid_checks, check_id, 'ensembl_assembly not set; cannot verify organism compatibility')
        return
      end

      tax_id = extract_tax_id(organism_term)
      if tax_id.blank?
        record_skip(valid_checks, check_id, 'organism_ontology_term_id missing or invalid')
        return
      end

      unless @lookup.remote_available?
        record_skip(valid_checks, check_id, 'ASAP reference assemblies unavailable')
        return
      end

      assemblies = @lookup.assemblies_for_tax_id(tax_id)
      if assemblies.empty?
        record_skip(valid_checks, check_id, 'No assemblies found in ASAP for this organism')
        return
      end

      matches = @lookup.matching_assemblies(assemblies, assembly, release: release)
      if matches.any?
        record_pass(valid_checks, check_id, "ensembl_assembly #{assembly} matches #{organism_term} at release #{release}")
        return
      end

      if release.present? && @lookup.assembly_matches_name?(assemblies, assembly)
        message = "ensembl_assembly #{assembly} matches the organism but not ensembl_release #{release}"
      else
        known = assemblies.map(&:name).join(', ')
        message = "ensembl_assembly #{assembly} is not a known assembly for #{organism_term} (known: #{known})"
      end
      record_failure(errors, valid_checks, check_id:, message:)
    end

    def parse_ensembl_release
      raw = first_uns_value('ensembl_release')
      return nil if raw.blank? || !raw.match?(/\A\d+\z/)

      raw.to_i
    end

    def first_uns_value(name)
      path = Rules.field_path(@format, :uns, name)
      Array(@field_values[path] || @field_values[path.to_sym]).first.to_s.strip.presence
    end

    def extract_tax_id(term_id)
      match = term_id.to_s.match(/\ANCBITaxon:(\d+)\z/)
      return nil unless match

      match[1].to_i
    end

    def record_pass(valid_checks, field, message)
      valid_checks << { field: field, status: 'passed', message: message }
    end

    def record_skip(valid_checks, field, message)
      valid_checks << { field: field, status: 'skipped', message: message }
    end

    def record_failure(errors, valid_checks, check_id:, message:)
      errors << { field: check_id, message: message }
      valid_checks << { field: check_id, status: 'failed', message: message }
    end
  end
end
