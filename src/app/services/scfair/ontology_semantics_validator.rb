# frozen_string_literal: true

module Scfair
  class OntologySemanticsValidator
    def initialize(field_values:, format:)
      @field_values = field_values || {}
      @format = format
      @resolver = OntologyLineageResolver.new
      @errors = []
      @warnings = []
      @valid_checks = []
    end

    def call
      checks = []
      field_names.each do |field_name|
        rules = OntologySemanticRules.rules_for(field_name)
        next if rules.blank?
        path = path_for(field_name)
        values = split_values(@field_values[path])
        next if values.empty?

        allowed_check_failed = false
        banned_check_failed = false
        lineage_check_failed = false
        special_check_failed = false
        ordering_check_failed = false
        allowed_specials = OntologySemanticRules.allowed_special_values_for(field_name)

        ordering_failures = []
        if rules[:sorted_multi]
          ordering_failures = multi_value_ordering_failures(@field_values[path], allowed_specials)
          if ordering_failures.any?
            delimiter = Rules.multi_value_delimiter
            @errors << {
              field: "ontology.semantics.#{field_name}.ordering",
              message: "#{field_name} values must be unique and sorted lexically with '#{delimiter}' separator — #{ordering_failures.join('; ')}"
            }
            ordering_check_failed = true
          end
        end

        values.each do |identifier|
          next if special_value?(identifier, allowed_specials)

          unless @resolver.exists?(identifier)
            @errors << { field: "ontology.semantics.#{field_name}.existence", message: "#{identifier}: term not found in ontology DB" }
            allowed_check_failed = true
            next
          end

          if rules[:allowed_exact]&.include?(identifier)
            next
          end

          next if cellosaurus_term?(field_name, identifier)

          if rules[:any_roots].present?
            ok = rules[:any_roots].any? { |root| @resolver.descendant_of?(identifier, root) }
            unless ok
              @errors << { field: "ontology.semantics.#{field_name}.lineage", message: "#{identifier}: must be under #{rules[:any_roots].join(' or ')}" }
              lineage_check_failed = true
            end
          elsif rules[:allowed_exact].present?
            @errors << {
              field: "ontology.semantics.#{field_name}.allowed_terms",
              message: "#{identifier}: not an allowed term for #{field_name}"
            }
            allowed_check_failed = true
          end

          if rules[:forbidden_branches].present?
            rules[:forbidden_branches].each do |root|
              if @resolver.descendant_of?(identifier, root)
                @errors << { field: "ontology.semantics.#{field_name}.lineage", message: "#{identifier}: must not be under #{root}" }
                banned_check_failed = true
              end
            end
          end

          if rules[:forbidden_exact]&.include?(identifier)
            @errors << { field: "ontology.semantics.#{field_name}.forbidden", message: "#{identifier}: forbidden term for #{field_name}" }
            banned_check_failed = true
          end
        end

        pair = check_label_id_pair(field_name, values, allowed_specials)
        if pair[:error]
          @errors << pair[:error]
          checks << {
            field: pair[:error][:field],
            status: 'failed',
            message: pair[:error][:message]
          }
          special_check_failed = true if pair[:error][:field].to_s.include?('special')
        elsif pair[:check]
          checks << pair[:check]
        end

        checks << {
          field: "ontology.semantics.#{field_name}.allowed_terms",
          status: allowed_check_failed ? 'failed' : 'passed',
          message: allowed_check_failed ? 'Allowed/known ontology term checks failed' : 'Allowed/known ontology term checks passed'
        }

        if rules[:forbidden_exact].present? || rules[:forbidden_branches].present?
          checks << {
            field: "ontology.semantics.#{field_name}.banned_terms",
            status: banned_check_failed ? 'failed' : 'passed',
            message: banned_check_failed ? 'Banned ontology term checks failed' : 'Banned ontology term checks passed'
          }
        end

        if rules[:any_roots].present?
          checks << {
            field: "ontology.semantics.#{field_name}.descendants",
            status: lineage_check_failed ? 'failed' : 'passed',
            message: lineage_check_failed ? 'Descendant/root restriction checks failed' : 'Descendant/root restriction checks passed'
          }
        end

        if rules[:sorted_multi]
          checks << {
            field: "ontology.semantics.#{field_name}.sorted_multi",
            status: ordering_check_failed ? 'failed' : 'passed',
            message: if ordering_check_failed
                       "Multi-value ordering/uniqueness failed — #{ordering_failures.join('; ')}"
                     else
                       'Multi-value ordering/uniqueness passed'
                     end
          }
        end

        if allowed_specials.any?
          special_list = allowed_specials.join(', ')
          checks << {
            field: "ontology.semantics.#{field_name}.special_values",
            status: special_check_failed ? 'failed' : 'passed',
            message: if special_check_failed
                       "Special-value checks failed (allowed: #{special_list})"
                     else
                       "Special-value checks passed (allowed: #{special_list})"
                     end
          }
        end
      end

      { errors: @errors.uniq, warnings: @warnings.uniq, valid_checks: (@valid_checks + checks).uniq }
    end

    private

    def field_names
      Rules.semantic_field_names
    end

    def path_for(field_name)
      if @format == 'h5ad'
        "obs/#{field_name}"
      else
        "/col_attrs/#{field_name}"
      end
    end

    def split_values(raw)
      Array(raw).flat_map { |v| Rules.split_multi_value(v) }
    end

    def multi_value_ordering_failures(raw_values, allowed_specials)
      delimiter = Rules.multi_value_delimiter
      Array(raw_values).filter_map do |raw|
        parts = Rules.split_multi_value(raw)
        next if parts.size <= 1

        normalized = parts.reject { |v| special_value?(v, allowed_specials) }
        next if normalized.empty?

        issues = []
        if normalized.uniq.size != normalized.size
          dups = normalized.group_by(&:itself).select { |_term, occurrences| occurrences.size > 1 }.keys
          issues << "duplicate #{'term'.pluralize(dups.size)} #{dups.join(', ')}"
        end
        if normalized != normalized.sort
          issues << "not sorted lexically (expected #{normalized.sort.join(delimiter)})"
        end
        next if issues.empty?

        %("#{raw}": #{issues.join('; ')})
      end
    end

    def special_value?(v, allowed_specials = nil)
      return false if allowed_specials.blank?

      allowed_specials.include?(v)
    end

    def cellosaurus_term?(field_name, identifier)
      identifier.to_s.start_with?('CVCL_') && Rules.ontology_prefixes(field_name).include?('CVCL')
    end

    def check_label_id_pair(field_name, id_values, allowed_specials = [])
      return {} if Rules.obs_label_pair_fields.key?(field_name.to_s)
      label_field = OntologySemanticRules.label_field_name(field_name)
      return {} if label_field.blank?

      path = path_for(field_name)
      pairs_key = "#{path}#label_pairs"
      pair_entries = Array(@field_values[pairs_key]).map(&:to_s).map(&:strip).reject(&:blank?)
      return check_extracted_label_pairs(field_name, pair_entries, allowed_specials) if pair_entries.any?

      label_path = path_for(label_field)
      labels = split_values(@field_values[label_path])
      return {} if labels.empty?

      if labels.size != id_values.size
        return {
          error: {
            field: "ontology.semantics.#{field_name}.label_pair",
            message: "#{field_name} and #{label_field} must contain the same number of ' || '-separated values"
          }
        }
      end

      id_values.each_with_index do |identifier, idx|
        pair_error = validate_label_for_identifier(field_name, identifier, labels[idx].to_s, allowed_specials)
        return pair_error if pair_error
      end

      {
        check: {
          field: "ontology.semantics.#{field_name}.label_pair",
          status: 'passed',
          message: 'ID/label pairs are coherent'
        }
      }
    end

    def check_extracted_label_pairs(field_name, pair_entries, allowed_specials)
      pair_entries.each do |entry|
        id_val, label_val = entry.to_s.split(' || ', 2).map(&:strip)
        next if id_val.blank?

        pair_error = validate_label_for_identifier(field_name, id_val, label_val.to_s, allowed_specials)
        return pair_error if pair_error
      end

      {
        check: {
          field: "ontology.semantics.#{field_name}.label_pair",
          status: 'passed',
          message: 'ID/label pairs are coherent'
        }
      }
    end

    def validate_label_for_identifier(field_name, identifier, label, allowed_specials)
      if special_value?(identifier, allowed_specials)
        return nil if label == identifier

        return {
          error: {
            field: "ontology.semantics.#{field_name}.special_label_pair",
            message: "Label must match special ontology id value -- expected #{identifier}, got #{label}"
          }
        }
      end

      term = CellOntologyTerm.active_original_by_identifier(identifier)
      return nil if term && term.name.to_s == label

      expected = term&.name || 'n/a'
      {
        error: {
          field: "ontology.semantics.#{field_name}.label_pair",
          message: "ID/label mismatch for #{identifier}: expected '#{expected}', got '#{label}'"
        }
      }
    end
  end
end
