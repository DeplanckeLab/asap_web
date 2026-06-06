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
        field_failed = false

        allowed_check_failed = false
        banned_check_failed = false
        lineage_check_failed = false
        special_check_failed = false
        ordering_check_failed = false
        allowed_specials = OntologySemanticRules.allowed_special_values_for(field_name)

        if rules[:sorted_multi]
          normalized = values.reject { |v| special_value?(v, allowed_specials) }
          sorted = normalized.sort
          if normalized != sorted || normalized.uniq.size != normalized.size
            @errors << {
              field: "ontology.semantics.#{field_name}.ordering",
              message: "#{field_name} values must be unique and sorted lexically with ' || ' separator"
            }
            field_failed = true
            ordering_check_failed = true
          end
        end

        values.each do |identifier|
          next if special_value?(identifier, allowed_specials)

          unless @resolver.exists?(identifier)
            @errors << { field: "ontology.semantics.#{field_name}.existence", message: "#{identifier}: term not found in ontology DB" }
            field_failed = true
            allowed_check_failed = true
            next
          end

          if rules[:allowed_exact]&.include?(identifier)
            next
          end

          if rules[:any_roots].present?
            ok = rules[:any_roots].any? { |root| @resolver.descendant_of?(identifier, root) }
            unless ok
              @errors << { field: "ontology.semantics.#{field_name}.lineage", message: "#{identifier}: must be under #{rules[:any_roots].join(' or ')}" }
              field_failed = true
              lineage_check_failed = true
            end
          end

          if rules[:forbidden_branches].present?
            rules[:forbidden_branches].each do |root|
              if @resolver.descendant_of?(identifier, root)
                @errors << { field: "ontology.semantics.#{field_name}.lineage", message: "#{identifier}: must not be under #{root}" }
                field_failed = true
                banned_check_failed = true
              end
            end
          end

          if rules[:forbidden_exact]&.include?(identifier)
            @errors << { field: "ontology.semantics.#{field_name}.forbidden", message: "#{identifier}: forbidden term for #{field_name}" }
            field_failed = true
            banned_check_failed = true
          end
        end

        pair = check_label_id_pair(field_name, values, allowed_specials)
        if pair[:error]
          @errors << pair[:error]
          field_failed = true
          special_check_failed = true if pair[:error][:field].to_s.include?('special')
        elsif pair[:check]
          checks << pair[:check]
        end

        checks << {
          field: "ontology.semantics.#{field_name}.allowed_terms",
          status: allowed_check_failed ? 'failed' : 'passed',
          message: allowed_check_failed ? 'Allowed/known ontology term checks failed' : 'Allowed/known ontology term checks passed'
        }
        checks << {
          field: "ontology.semantics.#{field_name}.banned_terms",
          status: banned_check_failed ? 'failed' : 'passed',
          message: banned_check_failed ? 'Banned ontology term checks failed' : 'Banned ontology term checks passed'
        }
        checks << {
          field: "ontology.semantics.#{field_name}.descendants",
          status: lineage_check_failed ? 'failed' : 'passed',
          message: lineage_check_failed ? 'Descendant/root restriction checks failed' : 'Descendant/root restriction checks passed'
        }
        if rules[:sorted_multi]
          checks << {
            field: "ontology.semantics.#{field_name}.sorted_multi",
            status: ordering_check_failed ? 'failed' : 'passed',
            message: ordering_check_failed ? 'Multi-value ordering/uniqueness failed' : 'Multi-value ordering/uniqueness passed'
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

        checks << {
          field: "ontology.semantics.#{field_name}",
          status: field_failed ? 'failed' : 'passed',
          message: field_failed ? "Semantic constraints failed for #{field_name}" : "Semantic constraints satisfied for #{field_name}"
        }
      end

      if @errors.empty?
        @valid_checks << { field: 'ontology.semantics', status: 'passed', message: 'Ontology semantic constraints satisfied' }
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
      Array(raw).flat_map { |v| v.to_s.split(' || ') }.map(&:strip).reject(&:blank?)
    end

    def special_value?(v, allowed_specials = nil)
      return false if allowed_specials.blank?

      allowed_specials.include?(v)
    end

    def check_label_id_pair(field_name, id_values, allowed_specials = [])
      label_field = OntologySemanticRules.label_field_name(field_name)
      return {} if label_field.blank?

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
        label = labels[idx].to_s
        if special_value?(identifier, allowed_specials)
          next if label == identifier
          return {
            error: {
              field: "ontology.semantics.#{field_name}.special_label_pair",
              message: "Label must match special ontology id value -- expected #{identifier}, got #{label}"
            }
          }
        end

        term = CellOntologyTerm.find_by(identifier: identifier, original: true)
        next if term && term.name.to_s == label

        expected = term&.name || 'n/a'
        return {
          error: {
            field: "ontology.semantics.#{field_name}.label_pair",
            message: "ID/label mismatch for #{identifier}: expected '#{expected}', got '#{label}'"
          }
        }
      end

      {
        check: {
          field: "ontology.semantics.#{field_name}.label_pair",
          status: 'passed',
          message: 'ID/label pairs are coherent'
        }
      }
    end
  end
end
