# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairFeatureReferenceTaxonPolicyTest < TestBaseWithoutFixtures
  LineageStub = Struct.new(:descendants, keyword_init: true) do
    def descendant_of?(tax_id, ancestor_tax_id)
      descendants.fetch([tax_id.to_i, ancestor_tax_id.to_i], false)
    end

    def taxonomy_available?
      true
    end
  end

  def policy_with_lineage(descendants)
    Scfair::FeatureReferenceTaxonPolicy.new(
      lineage_resolver: LineageStub.new(descendants: descendants)
    )
  end

  test 'allows metazoa gene references such as mosquito' do
    policy = policy_with_lineage({ [7159, 33208] => true })

    assert policy.allowed?('NCBITaxon:7159', biotype: 'gene')
  end

  test 'allows vertebrate and covid gene references' do
    policy = policy_with_lineage({ [9606, 33208] => true, [10090, 7742] => true })

    assert policy.allowed?('NCBITaxon:9606', biotype: 'gene')
    assert policy.allowed?('NCBITaxon:10090', biotype: 'gene')
    assert policy.allowed?('NCBITaxon:2697049', biotype: 'gene')
  end

  test 'allows only spike-in taxon for spike-in biotype' do
    policy = policy_with_lineage({})

    assert policy.allowed?('NCBITaxon:32630', biotype: 'spike-in')
    refute policy.allowed?('NCBITaxon:9606', biotype: 'spike-in')
  end

  test 'rejects non-metazoa gene references' do
    policy = policy_with_lineage({ [3702, 33208] => false })

    refute policy.allowed?('NCBITaxon:3702', biotype: 'gene')
  end
end
