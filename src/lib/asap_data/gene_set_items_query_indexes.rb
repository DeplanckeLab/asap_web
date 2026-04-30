# frozen_string_literal: true

module AsapData
  # Btree index aligned with gene_set_collection_items ORDER BY LOWER(COALESCE(name, '')).
  # Optional GIN (pg_trgm) for LOWER(COALESCE(name, '')) LIKE '%...%' filters.
  # Apply with: bin/rails asap_data:ensure_gene_set_items_query_indexes
  module GeneSetItemsQueryIndexes
    module_function

    BTREE_INDEX = "idx_gene_set_items_gene_set_lower_name"
    GIN_INDEX = "idx_gene_set_items_name_gin_trgm"

    def apply!(conn)
      begin
        conn.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("[AsapData::GeneSetItemsQueryIndexes] pg_trgm not available: #{e.message.strip}")
      end

      conn.execute(<<~SQL)
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{BTREE_INDEX}
        ON gene_set_items (gene_set_id, lower(coalesce(name, ''::text)))
      SQL

      return unless extension_enabled?(conn, "pg_trgm")

      conn.execute(<<~SQL)
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{GIN_INDEX}
        ON gene_set_items USING gin (lower(coalesce(name, ''::text)) gin_trgm_ops)
      SQL
    end

    def revert!(conn)
      conn.execute("DROP INDEX IF EXISTS #{GIN_INDEX}")
      conn.execute("DROP INDEX IF EXISTS #{BTREE_INDEX}")
    end

    def extension_enabled?(conn, name)
      conn.select_value(
        "SELECT 1 FROM pg_extension WHERE extname = #{conn.quote(name)}"
      ).present?
    end

    def apply_all_remote_shards!
      target_remote_versions.each do |db_name|
        RemoteGene.with_remote(db_name) do
          conn = Asap2RemoteRecord.connection
          Rails.logger.info("[AsapData::GeneSetItemsQueryIndexes] applying on #{db_name}")
          apply!(conn)
        end
      end
    end

    def target_remote_versions
      explicit_targets = ENV["ASAP2_INDEX_TARGET_DBS"].to_s
      return explicit_targets.split(",").map(&:strip).reject(&:blank?) if explicit_targets.present?

      default_target = ENV["ASAP2_REMOTE_DB"].to_s.strip
      return [default_target] if default_target.present?

      RemoteGene.remote_versions
    end
  end
end
