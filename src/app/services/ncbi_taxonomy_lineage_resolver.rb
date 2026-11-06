# frozen_string_literal: true

require "set"

# Resolves NCBI taxonomy lineages from ncbi_taxonomy_nodes (loaded by `rails ncbi_taxonomy:load_nodes`).
#
# Used for clade-based applicability: a taxon-specific ontology (CellOntology#tax_ids, rules.yaml
# cross_field.organism_* maps) applies to an organism when the organism is the listed taxon or one of
# its descendants (scFAIR Appendix B: clade-specific ontologies).
#
# A tax_id absent from the table resolves to [tax_id] only, so clade matching degrades to exact matching.
# Only resolved lineages are memoized, so a later taxonomy load is picked up without restart.
class NcbiTaxonomyLineageResolver
  MAX_DEPTH = 200
  SHARED_CACHE_LIMIT = 20_000

  LINEAGE_SQL = <<~SQL
    WITH RECURSIVE lineage(tax_id, parent_tax_id, depth) AS (
      SELECT tax_id, parent_tax_id, 0 FROM ncbi_taxonomy_nodes WHERE tax_id = ?
      UNION ALL
      SELECT n.tax_id, n.parent_tax_id, l.depth + 1
      FROM ncbi_taxonomy_nodes n
      JOIN lineage l ON n.tax_id = l.parent_tax_id
      WHERE l.parent_tax_id IS NOT NULL AND l.parent_tax_id <> l.tax_id AND l.depth < #{MAX_DEPTH}
    )
    SELECT tax_id FROM lineage ORDER BY depth
  SQL

  # Process-wide instance (lineages are stable between taxonomy reloads).
  def self.shared
    @shared ||= new(cache: Concurrent::Map.new)
  end

  def initialize(cache: {})
    @lineages = cache
  end

  # [tax_id, parent, grandparent, ..., root]; [tax_id] when unknown; [] when tax_id is not positive.
  def self_and_ancestors(tax_id)
    tax_id = tax_id.to_i
    return [] unless tax_id.positive?

    cached = @lineages[tax_id]
    return cached if cached

    lineage = fetch_lineage(tax_id)
    return [tax_id].freeze if lineage.empty?

    @lineages.clear if @lineages.size >= SHARED_CACHE_LIMIT
    @lineages[tax_id] = lineage.freeze
  end

  def known?(tax_id)
    self_and_ancestors(tax_id).size > 1
  end

  def descendant_of?(tax_id, ancestor_tax_id)
    ancestor = ancestor_tax_id.to_i
    ancestor.positive? && self_and_ancestors(tax_id).include?(ancestor)
  end

  # Steps from tax_id up to the closest of candidate_tax_ids (0 = same taxon); nil when none applies.
  def distance_to_nearest(tax_id, candidate_tax_ids)
    candidates = Array(candidate_tax_ids).map(&:to_i).select(&:positive?).to_set
    return nil if candidates.empty?

    self_and_ancestors(tax_id).index { |id| candidates.include?(id) }
  end

  def taxonomy_available?
    NcbiTaxonomyNode.table_exists? && NcbiTaxonomyNode.exists?
  rescue StandardError
    false
  end

  private

  def fetch_lineage(tax_id)
    sql = ActiveRecord::Base.sanitize_sql_array([LINEAGE_SQL, tax_id])
    ActiveRecord::Base.connection.select_values(sql).map(&:to_i)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[NcbiTaxonomyLineageResolver] lineage lookup failed for #{tax_id}: #{e.message}")
    []
  end
end
