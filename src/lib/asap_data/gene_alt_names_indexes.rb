# frozen_string_literal: true

module AsapData
  # Btree indexes on full alt_names text hit PostgreSQL's ~8KB index row limit.
  # Replace with GIN (pg_trgm) indexes that support ILIKE / regex search on long values.
  module GeneAltNamesIndexes
    module_function

    LEGACY_BTREE_INDEXES = %w[
      organism_alt_names_idx
      organism_lc_alt_names_idx
    ].freeze

    GIN_ALT_NAMES_INDEX = "genes_alt_names_gin_trgm_idx"
    GIN_LC_ALT_NAMES_INDEX = "genes_lc_alt_names_gin_trgm_idx"

    def apply!(conn)
      conn.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

      LEGACY_BTREE_INDEXES.each do |index_name|
        conn.execute("DROP INDEX IF EXISTS #{index_name}")
      end

      return unless extension_enabled?(conn, "pg_trgm")

      conn.execute(<<~SQL)
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{GIN_ALT_NAMES_INDEX}
        ON genes USING gin (alt_names gin_trgm_ops)
        WHERE alt_names IS NOT NULL AND alt_names <> ''
      SQL

      conn.execute(<<~SQL)
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{GIN_LC_ALT_NAMES_INDEX}
        ON genes USING gin (lower(alt_names) gin_trgm_ops)
        WHERE alt_names IS NOT NULL AND alt_names <> ''
      SQL
    end

    def revert!(conn)
      conn.execute("DROP INDEX IF EXISTS #{GIN_LC_ALT_NAMES_INDEX}")
      conn.execute("DROP INDEX IF EXISTS #{GIN_ALT_NAMES_INDEX}")

      conn.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS organism_alt_names_idx
        ON genes (organism_id, alt_names)
      SQL

      conn.execute(<<~SQL)
        CREATE INDEX IF NOT EXISTS organism_lc_alt_names_idx
        ON genes (organism_id, lower(alt_names))
      SQL
    end

    def extension_enabled?(conn, name)
      conn.select_value(
        "SELECT 1 FROM pg_extension WHERE extname = #{conn.quote(name)}"
      ).present?
    end

    def apply_remote!(remote_db: ENV.fetch("ASAP2_REMOTE_DB", "asap_data_v8"))
      RemoteGene.with_remote(remote_db) do
        apply!(RemoteGene.connection)
      end
    end
  end
end
