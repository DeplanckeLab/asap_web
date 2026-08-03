# frozen_string_literal: true

module Scfair
  # Project-compliance check: warn when ASAP consensus metadata
  # (/col_attrs/_asap_consensus_<X>) differs from the official scFAIR field (<X>
  # / OntologyTermType label_path).
  class ConsensusOfficialMetadataValidator
    CONSENSUS_PREFIX = '_asap_consensus_'
    BKP_SUFFIX = /\.bkp\.\d+\z/
    ONTOLOGY_ID_SUFFIX = '_ontology_term_id'

    def initialize(file_path:, field_values:, format:, project_compliance: false)
      @file_path = file_path.to_s
      @field_values = field_values || {}
      @format = format.to_s
      @project_compliance = project_compliance
    end

    def call
      return empty_result unless applicable?

      pairs = comparison_pairs
      return empty_result if pairs.empty?

      compare_paths = pairs.flat_map { |entry| entry[:compare] }
      results_by_key = compare_results_index(compare_paths)
      warnings = build_warnings(pairs, results_by_key)

      { errors: [], warnings: warnings, valid_checks: [] }
    end

    private

    def empty_result
      { errors: [], warnings: [], valid_checks: [] }
    end

    def applicable?
      @project_compliance && @format == 'loom' && @file_path.present? && File.exist?(@file_path)
    end

    def obs_column_names
      raw = @field_values[Rules.metadata_column_list_key('obs')] ||
            @field_values[Rules.metadata_column_list_key('obs').to_sym]
      Array(raw).map(&:to_s).reject(&:blank?)
    end

    def consensus_label_columns
      obs_column_names.select do |name|
        name.start_with?(CONSENSUS_PREFIX) &&
          !name.end_with?(ONTOLOGY_ID_SUFFIX) &&
          !name.match?(BKP_SUFFIX) &&
          !name.match?(/#{Regexp.escape(ONTOLOGY_ID_SUFFIX)}\.bkp\.\d+\z/)
      end
    end

    def ott_by_name
      @ott_by_name ||= OntologyTermType.all.index_by { |ott| ott.name.to_s }
    end

    def comparison_pairs
      columns = obs_column_names.to_set
      consensus_label_columns.filter_map do |consensus_name|
        tag = consensus_name.delete_prefix(CONSENSUS_PREFIX)
        next if tag.blank?

        official = resolve_official_paths(tag, columns)
        next unless official

        compare = []
        compare << {
          a: "/col_attrs/#{consensus_name}",
          b: official[:label_path]
        }
        if official[:consensus_term_path] && official[:term_path] &&
           columns.include?(File.basename(official[:consensus_term_path])) &&
           columns.include?(File.basename(official[:term_path]))
          compare << {
            a: official[:consensus_term_path],
            b: official[:term_path]
          }
        end

        {
          tag: tag,
          display_name: official[:display_name],
          field: official[:label_path],
          compare: compare
        }
      end
    end

    def resolve_official_paths(tag, columns)
      ott = ott_by_name[tag]
      if ott&.label_path.present?
        label_path = ott.label_path.to_s
        label_basename = File.basename(label_path)
        return nil unless columns.include?(label_basename)

        term_path = ott.term_path.to_s.presence
        {
          display_name: label_basename,
          label_path: label_path,
          term_path: term_path,
          consensus_term_path: "/col_attrs/#{CONSENSUS_PREFIX}#{tag}#{ONTOLOGY_ID_SUFFIX}"
        }
      elsif columns.include?(tag)
        {
          display_name: tag,
          label_path: "/col_attrs/#{tag}",
          term_path: columns.include?("#{tag}#{ONTOLOGY_ID_SUFFIX}") ? "/col_attrs/#{tag}#{ONTOLOGY_ID_SUFFIX}" : nil,
          consensus_term_path: "/col_attrs/#{CONSENSUS_PREFIX}#{tag}#{ONTOLOGY_ID_SUFFIX}"
        }
      end
    end

    def compare_results_index(compare_paths)
      results = H5DataService.compare_metadata_vector_pairs(@file_path, compare_paths)
      Array(results).each_with_object({}) do |entry, index|
        key = [entry['a'].to_s, entry['b'].to_s]
        index[key] = entry
      end
    end

    def build_warnings(pairs, results_by_key)
      pairs.filter_map do |entry|
        differs = entry[:compare].any? do |pair|
          a = strip_leading_slash(pair[:a])
          b = strip_leading_slash(pair[:b])
          result = results_by_key[[a, b]]
          result && result['missing'] != true && result['equal'] == false
        end
        next unless differs

        name = entry[:display_name]
        {
          field: entry[:field],
          message: "The last ASAP consensus annotation for #{name} metadata is not the final scFAIR official annotation. " \
                   "In order to publish this consensus annotation, please click on the \"Edit Metadata\" button and use " \
                   "the consensus annotation metadata as template."
        }
      end
    end

    def strip_leading_slash(path)
      path.to_s.sub(%r{\A/}, '')
    end
  end
end
