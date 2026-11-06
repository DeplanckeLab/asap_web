# frozen_string_literal: true

require_relative 'test_base_without_fixtures'
require 'minitest/mock'

# Clade semantics of CellOntology#tax_ids, Basic taxonomy priority, and rules.yaml organism maps
# (cross_field.organism_taxon_match: self_or_descendant). Lineages are stubbed (no DB taxonomy needed).
class TaxonCladeApplicabilityTest < TestBaseWithoutFixtures
  # Real NCBI ids: Diptera > Culicidae ... > Aedes aegypti; Diptera > ... > Drosophila melanogaster.
  LINEAGES = {
    7159 => [7159, 7158, 7157, 7148, 7147, 50557, 33208, 1],     # Aedes aegypti
    7227 => [7227, 32351, 7215, 7214, 43746, 7147, 50557, 33208, 1], # Drosophila melanogaster
    7240 => [7240, 32351, 7215, 7214, 43746, 7147, 50557, 33208, 1], # Drosophila simulans
    6238 => [6238, 6237, 55885, 6236, 6231, 33208, 1],         # Caenorhabditis briggsae
    9606 => [9606, 9605, 207598, 9443, 40674, 7742, 33208, 1],   # Homo sapiens
    10090 => [10090, 10088, 10066, 9989, 40674, 7742, 33208, 1]  # Mus musculus
  }.freeze

  class LineageStub
    def initialize(lineages)
      @lineages = lineages
    end

    def self_and_ancestors(tax_id)
      tax_id = tax_id.to_i
      return [] unless tax_id.positive?

      @lineages.fetch(tax_id, [tax_id])
    end

    def distance_to_nearest(tax_id, candidates)
      ids = candidates.map(&:to_i)
      self_and_ancestors(tax_id).index { |id| ids.include?(id) }
    end
  end

  Term = Struct.new(:id, :original, :cell_ontology, keyword_init: true)

  def lineage
    @lineage ||= LineageStub.new(LINEAGES)
  end

  def with_shared_lineage(&block)
    NcbiTaxonomyLineageResolver.stub(:shared, lineage, &block)
  end

  test 'CellOntology tax_ids apply to the listed clade and its descendants only' do
    fbdv = CellOntology.new(tag: 'FBdv', tax_ids: '7147')
    fbbt = CellOntology.new(tag: 'FBbt', tax_ids: '7227')
    cl = CellOntology.new(tag: 'CL', tax_ids: '')

    assert fbdv.applies_to_tax_id?(7159, lineage: lineage)
    assert fbdv.applies_to_tax_id?('7227', lineage: lineage)
    refute fbdv.applies_to_tax_id?(9606, lineage: lineage)
    assert fbbt.applies_to_tax_id?(7227, lineage: lineage)
    refute fbbt.applies_to_tax_id?(7159, lineage: lineage)
    assert cl.applies_to_tax_id?(9606, lineage: lineage)
    assert cl.applies_to_tax_id?(nil, lineage: lineage)
    refute fbdv.applies_to_tax_id?(nil, lineage: lineage)

    assert_equal 0, fbbt.taxon_distance(7227, lineage: lineage)
    assert_equal 4, fbdv.taxon_distance(7159, lineage: lineage)
    assert_equal Float::INFINITY, cl.taxon_distance(7159, lineage: lineage)
  end

  test 'Basic prefers the most specific applicable ontology' do
    species = Term.new(id: 3, original: true, cell_ontology: CellOntology.new(tax_ids: '7227'))
    clade = Term.new(id: 2, original: true, cell_ontology: CellOntology.new(tax_ids: '7147'))
    neutral = Term.new(id: 1, original: true, cell_ontology: CellOntology.new(tax_ids: ''))
    other = Term.new(id: 4, original: true, cell_ontology: CellOntology.new(tax_ids: '9606'))
    terms = [neutral, clade, species, other]

    assert_equal [species], Basic.pick_terms_by_taxonomy_priority(terms, 7227, lineage: lineage)
    assert_equal [clade], Basic.pick_terms_by_taxonomy_priority(terms, 7159, lineage: lineage)
    assert_equal [neutral], Basic.pick_terms_by_taxonomy_priority(terms, 10090, lineage: lineage)

    assert_equal :exact, Basic.cell_ontology_match_tier(species, 7227, lineage: lineage)
    assert_equal :clade, Basic.cell_ontology_match_tier(clade, 7159, lineage: lineage)
    assert_equal :universal, Basic.cell_ontology_match_tier(neutral, 7159, lineage: lineage)
    assert_nil Basic.cell_ontology_match_tier(other, 7159, lineage: lineage)
    refute Basic.cell_ontology_term_applicable_to_tax_id?(other, 7159, lineage: lineage)
  end

  test 'rules.yaml uses clade matching for organism maps' do
    assert_equal 'self_or_descendant', Scfair::Rules.organism_taxon_match

    with_shared_lineage do
      assert_equal 'FBdv', Scfair::Rules.organism_dev_stage_prefix_for('NCBITaxon:7159')
      assert_equal 'FBdv', Scfair::Rules.organism_dev_stage_prefix_for('NCBITaxon:7227')
      assert_equal 'HsapDv', Scfair::Rules.organism_dev_stage_prefix_for('NCBITaxon:9606')
      assert_nil Scfair::Rules.organism_dev_stage_prefix_for('NCBITaxon:6238')
      assert_nil Scfair::Rules.organism_dev_stage_prefix_for('')

      # FBbt is scoped to D. melanogaster only.
      assert_includes Scfair::Rules.organism_cell_type_prefixes_for('NCBITaxon:7227'), 'FBbt'
      refute_includes Scfair::Rules.organism_cell_type_prefixes_for('NCBITaxon:7159'), 'FBbt'
      refute Scfair::Rules.organism_tissue_mapped?('NCBITaxon:7240')
    end
  end

  test 'organism-specific evaluator accepts FBdv for a non-melanogaster dipteran' do
    result = with_shared_lineage do
      Scfair::OrganismSpecificConstraintEvaluator.new(
        field_values: {
          'uns/organism_ontology_term_id' => ['NCBITaxon:7159'],
          'obs/development_stage_ontology_term_id' => ['FBdv:00005369']
        },
        format: 'h5ad'
      ).call
    end

    dev = result[:valid_checks].find { |check| check[:field] == 'ontology.organism_specific.development_stage' }
    assert_equal 'passed', dev[:status]
  end

  test 'organism-specific evaluator rejects FBdv for a non-dipteran' do
    result = with_shared_lineage do
      Scfair::OrganismSpecificConstraintEvaluator.new(
        field_values: {
          'uns/organism_ontology_term_id' => ['NCBITaxon:10090'],
          'obs/development_stage_ontology_term_id' => ['FBdv:00005369']
        },
        format: 'h5ad'
      ).call
    end

    assert result[:errors].any? { |entry| entry[:field] == 'ontology.organism_specific.development_stage' }
  end
end
