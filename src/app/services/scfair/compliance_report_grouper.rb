# frozen_string_literal: true

module Scfair
  class ComplianceReportGrouper
    def self.call(checks_catalog:, valid_checks:, errors:, warnings:, format:)
      new(
        checks_catalog: checks_catalog,
        valid_checks: valid_checks,
        errors: errors,
        warnings: warnings,
        format: format
      ).call
    end

    def self.category_for(field:, message:, format:, check_id: nil)
      new(
        checks_catalog: [],
        valid_checks: [],
        errors: [],
        warnings: [],
        format: format
      ).category_for({ field: field, message: message, check_id: check_id })
    end

    def initialize(checks_catalog:, valid_checks:, errors:, warnings:, format:)
      @checks_catalog = Array(checks_catalog)
      @valid_checks = Array(valid_checks)
      @errors = Array(errors)
      @warnings = Array(warnings)
      @format = format.to_s
    end

    def call
      grouped_items = Hash.new { |hash, key| hash[key] = {} }

      [@valid_checks, @errors, @warnings].each do |collection|
        collection.each do |entry|
          category_id = category_for(entry)
          next if category_id.blank?

          merge_item!(grouped_items[category_id], normalize_item(entry, collection))
        end
      end

      @checks_catalog.filter_map do |entry|
        id = entry[:id] || entry['id']
        label = entry[:label] || entry['label']
        items = grouped_items[id].values.sort_by { |item| field_sort_key(item[:field]) }
        next if items.empty?

        { id: id, label: label, items: items }
      end
    end

    def category_for(entry)
      check_id = entry[:check_id] || entry['check_id']
      return check_id.to_s if check_id.present?

      field = (entry[:field] || entry['field']).to_s
      message = (entry[:message] || entry['message']).to_s
      return nil if field.blank?

      return 'schema.version' if field.match?(/\A(uns\/schema_version|\/attrs\/schema_version)\z/)
      return 'cross-field.constraints' if field.start_with?('cross-field')
      return 'ontology.semantics' if field.start_with?('ontology.semantics.')
      return 'ontology.organism_specific' if field.start_with?('ontology.organism_specific')
      return 'extension.spatial' if field.start_with?('extension.spatial')
      return 'extension.perturb' if field.start_with?('extension.perturb')
      return 'extension.atac' if field.start_with?('extension.atac')
      return 'extension.analysis_json' if field.start_with?('extension.analysis_json')
      return 'metadata.other' if field.start_with?('metadata.other')
      return 'loom.mapping_manifest' if field.include?('anndata_mapping')
      return 'h5ad.embeddings' if field.start_with?('obsm')
      return 'h5ad.matrix_encoding' if field == 'X'
      return 'h5ad.structure' if field == 'obs'

      if ontology_term_field?(field)
        return 'ontology.database_resolution' if database_resolution_message?(message)
        return 'ontology.format' if ontology_format_message?(message) || passed_ontology_format?(message)
      end

      return 'cross-field.constraints' if cross_field_constraint_message?(field, message)

      return 'uns.required_presence' if field.start_with?('uns/')
      return 'obs.required_presence' if field.start_with?('obs/')
      return 'loom.paths' if field.start_with?('/col_attrs/') || field.start_with?('/attrs/') || field.in?(%w[file dimensions])

      nil
    end

    private

    def normalize_item(entry, collection)
      field = (entry[:field] || entry['field']).to_s
      message = entry[:message] || entry['message']
      explicit = (entry[:status] || entry['status']).to_s.strip.downcase

      status = if collection.equal?(@errors)
                 'failed'
               elsif collection.equal?(@warnings)
                 'warning'
               elsif explicit.present?
                 explicit
               else
                 'passed'
               end

      { field: field, message: message, status: status }
    end

    def merge_item!(bucket, item)
      field = item[:field]
      existing = bucket[field]
      return bucket[field] = item if existing.blank?

      priority = { 'failed' => 3, 'warning' => 2, 'passed' => 1, 'skipped' => 0 }
      if priority[item[:status]].to_i >= priority[existing[:status]].to_i
        bucket[field] = item
      end
    end

    def ontology_term_field?(field)
      field.include?('_ontology_term_id') ||
        field.match?(/\A\/attrs\/organism\z/) ||
        field.match?(/\Auns\/organism\z/)
    end

    def database_resolution_message?(message)
      message.match?(/authorised ontologies|found in.*ontolog|term not found in ontology DB|valid for '/i)
    end

    def ontology_format_message?(message)
      message.match?(/Invalid ontology|Unexpected ontology|ontology format|valid format|Invalid value/i)
    end

    def passed_ontology_format?(message)
      message.match?(/valid format|Ontology terms in .* have valid format/i)
    end

    CROSS_FIELD_METADATA_FIELDS = %w[
      suspension_type tissue_type donor_id assay_ontology_term_id
      self_reported_ethnicity_ontology_term_id sex_ontology_term_id
      development_stage_ontology_term_id tissue_ontology_term_id
      cell_type_ontology_term_id is_primary_data in_tissue
    ].freeze

    def field_sort_key(field)
      field = field.to_s
      cross_field = field.match(/\Across-field\.CF-(\d+)([a-z]*)-/i)
      return [0, cross_field[1].to_i, cross_field[2], field] if cross_field

      [1, field]
    end

    def cross_field_constraint_message?(field, message)
      return true if field.start_with?('cross-field')

      field_name = field.split('/').last.to_s
      return false unless CROSS_FIELD_METADATA_FIELDS.include?(field_name)

      message.match?(
        /MUST|must not|must be|For assay|tissue_type is|Organism is|Organoid|Visium|C\. elegans|spatial\.is_single|Label must match special ontology id/i
      )
    end
  end
end
