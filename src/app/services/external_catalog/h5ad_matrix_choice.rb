# frozen_string_literal: true

module ExternalCatalog
  # Main-matrix choice for catalog H5AD files that hold several matrices (/X, /raw/X, /layers/*).
  # Works on the preparsing list_groups entries; the rule itself is plain Ruby so it can be unit-tested.
  # Whatever is chosen, parsing keeps the other matrices as extra loom layers.
  module H5adMatrixChoice
    RAW_SEL = '/raw/X'
    X_SEL = '/X'
    # Layer names that conventionally hold the raw counts.
    COUNT_LAYER_NAMES = %w[counts count raw_counts raw_count raw].freeze
    # Layer names that look like counts ("raw_count_cellranger", "umi_counts", ...).
    COUNTISH_RE = /count|raw/i
    # Ambient-RNA corrected counts are preferred over the unprocessed Cell Ranger counts.
    CORRECTED_RE = /cellbender|soupx|decontx|decontaminated|corrected|ambient/i
    # RNA velocity layers hold counts but are not the expression matrix to analyse.
    VELOCITY_LAYER_NAMES = %w[spliced unspliced ambiguous].freeze

    module_function

    def normalize_path(path)
      p = path.to_s.strip
      return nil if p.empty?
      return p if p.start_with?('/')
      return X_SEL if p == 'X'

      "/layers/#{p}"
    end

    # One hash per matrix, in file order: path, nber_rows (genes), nber_cols (cells),
    # is_count (true / false / nil = unknown) and dtype.
    def choices(groups)
      Array(groups).filter_map do |g|
        next unless g.is_a?(Hash)

        path = normalize_path(g['group'])
        next unless path

        {
          'path' => path,
          'nber_rows' => integer_or_nil(g['nber_rows'] || g['nb_genes']),
          'nber_cols' => integer_or_nil(g['nber_cols'] || g['nb_cells']),
          'is_count' => count_flag(g['is_count']),
          'dtype' => g['dtype'].nil? ? nil : g['dtype'].to_s
        }
      end.uniq { |c| c['path'] }
    end

    # The user (or the default rule) has to pick when there is more than one matrix and no /raw/X.
    def ambiguous?(choices)
      paths = Array(choices).map { |c| c['path'] }
      paths.size > 1 && !paths.include?(RAW_SEL)
    end

    # Path of the matrix to preselect / use when nobody chooses. Ties keep file order.
    def recommended(choices)
      list = Array(choices)
      return nil if list.empty?

      list.each_with_index.min_by { |c, i| [rank(c), i] }.first['path']
    end

    # Lower is better:
    #   0 /raw/X
    #   1 layer named counts / raw_counts / raw ...
    #   2 count-like layer that is ambient-corrected (CellBender, SoupX, DecontX)
    #   3 other count-like layer (e.g. raw_count_cellranger)
    #   4 /X holding integer counts
    #   5 other layer holding integer counts (not velocity)
    #   6 /X
    #   7 anything else
    # A layer whose values are known not to be integers never gets a count rank.
    def rank(choice)
      path = choice['path'].to_s
      is_count = choice['is_count']
      return 0 if path == RAW_SEL

      if path.start_with?('/layers/')
        name = path.delete_prefix('/layers/').downcase
        unless is_count == false
          return 1 if COUNT_LAYER_NAMES.include?(name)
          return 2 if name.match?(COUNTISH_RE) && name.match?(CORRECTED_RE)
          return 3 if name.match?(COUNTISH_RE)
        end
        return 5 if is_count == true && !VELOCITY_LAYER_NAMES.include?(name)

        return 7
      end
      return(is_count == true ? 4 : 6) if path == X_SEL

      7
    end

    # Choices for a downloaded, preparsed Fu (reads its output.json).
    def choices_for_fu(fu)
      output_path = fu.upload_dir.join('output.json')
      return [] unless File.exist?(output_path)

      output = Basic.safe_parse_json(File.read(output_path), {})
      choices(output['list_groups'])
    end

    def count_flag(value)
      case value
      when true, 1, '1', 'true' then true
      when false, 0, '0', 'false' then false
      end
    end

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
