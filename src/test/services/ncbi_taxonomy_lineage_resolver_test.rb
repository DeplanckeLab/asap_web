# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class NcbiTaxonomyLineageResolverTest < TestBaseWithoutFixtures
  # Synthetic tax_ids far outside the NCBI range: root <- order <- genus <- species.
  ROOT = 990_000_001
  ORDER = 990_000_002
  GENUS = 990_000_003
  SPECIES = 990_000_004
  UNKNOWN = 990_000_099
  IDS = [ROOT, ORDER, GENUS, SPECIES].freeze

  setup do
    now = Time.current
    rows = [
      [ROOT, ROOT, 'no rank'],
      [ORDER, ROOT, 'order'],
      [GENUS, ORDER, 'genus'],
      [SPECIES, GENUS, 'species']
    ].map do |tax_id, parent, rank|
      { tax_id: tax_id, parent_tax_id: parent, rank: rank, scientific_name: "test #{rank}", created_at: now, updated_at: now }
    end
    NcbiTaxonomyNode.upsert_all(rows, unique_by: :tax_id)
  end

  teardown do
    NcbiTaxonomyNode.where(tax_id: IDS).delete_all
  end

  test 'self_and_ancestors walks to the root, self first' do
    assert_equal [SPECIES, GENUS, ORDER, ROOT], NcbiTaxonomyLineageResolver.new.self_and_ancestors(SPECIES)
  end

  test 'unknown tax_id resolves to itself only (exact-match fallback)' do
    resolver = NcbiTaxonomyLineageResolver.new

    assert_equal [UNKNOWN], resolver.self_and_ancestors(UNKNOWN)
    refute resolver.known?(UNKNOWN)
    assert resolver.descendant_of?(UNKNOWN, UNKNOWN)
  end

  test 'descendant_of? and distance_to_nearest use the closest listed clade' do
    resolver = NcbiTaxonomyLineageResolver.new

    assert resolver.descendant_of?(SPECIES, ORDER)
    refute resolver.descendant_of?(ORDER, SPECIES)
    assert_equal 0, resolver.distance_to_nearest(SPECIES, [SPECIES, ORDER])
    assert_equal 1, resolver.distance_to_nearest(SPECIES, [GENUS, ORDER])
    assert_equal 2, resolver.distance_to_nearest(SPECIES, [ORDER])
    assert_nil resolver.distance_to_nearest(ORDER, [GENUS])
  end
end
