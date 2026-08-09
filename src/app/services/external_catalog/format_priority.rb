# frozen_string_literal: true

module ExternalCatalog
  # Shared format-selection rules for catalog imports.
  module FormatPriority
    # GEO single-cell / nucleus expression matrices (first match wins per GSE).
    # Extensions are matched case-insensitively; compound suffixes listed longest-first.
    GEO_SC_EXTENSIONS = [
      ['.loom', :loom],
      ['.h5ad', :h5ad],
      ['.rds.gz', :rds],
      ['.rdata.gz', :rds],
      ['.rds', :rds],
      ['.rdata', :rds],
      ['.mtx.gz', :mtx],
      ['.mtx', :mtx]
    ].freeze

    GEO_SC_PRIORITY = %i[loom h5ad rds mtx].freeze

    # GEO bulk expression matrices (first match wins per GSE).
    # Prefer deposited count/TPM tables over series_matrix: HT-seq series_matrix
    # files often contain only SOFT metadata with an empty expression table.
    GEO_BULK_PRIORITY = %i[counts_table series_matrix archive_table].freeze

    module_function

    def geo_sc_kind_for_filename(filename)
      name = filename.to_s.downcase
      GEO_SC_EXTENSIONS.each do |suffix, kind|
        return kind if name.end_with?(suffix)
      end
      nil
    end

    # Among candidate filenames, pick the best SC matrix by GEO_SC_PRIORITY.
    # Returns [filename, kind] or nil.
    def pick_geo_sc_file(filenames)
      ranked = Array(filenames).filter_map do |name|
        kind = geo_sc_kind_for_filename(name)
        next unless kind

        [GEO_SC_PRIORITY.index(kind), name, kind]
      end
      return nil if ranked.empty?

      ranked.min_by { |rank, name, _| [rank, name.to_s] }.then { |_rank, name, kind| [name, kind] }
    end

    def geo_bulk_series_matrix?(filename)
      filename.to_s.downcase.include?('series_matrix') && filename.to_s.downcase.end_with?('.txt.gz', '.txt')
    end

    def geo_bulk_counts_table?(filename)
      name = filename.to_s.downcase
      return false if geo_bulk_series_matrix?(name)
      return false if geo_sc_kind_for_filename(name)

      name.match?(/\.(tsv|csv|txt)(\.gz)?\z/) &&
        name.match?(/count|tpm|fpkm|rpkm|expression|norm/i)
    end

    def geo_bulk_archive?(filename)
      name = filename.to_s.downcase
      name.end_with?('.tar', '.tar.gz', '.tgz', '.zip') && !name.end_with?('.fastq.tar')
    end

    def pick_geo_bulk_file(filenames)
      names = Array(filenames)

      counts = names.find { |n| geo_bulk_counts_table?(n) }
      return [counts, :counts_table] if counts

      series = names.find { |n| geo_bulk_series_matrix?(n) }
      return [series, :series_matrix] if series

      archive = names.find { |n| geo_bulk_archive?(n) }
      return [archive, :archive_table] if archive

      nil
    end
  end
end
