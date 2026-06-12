# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairOntologyLineageResolverTest < TestBaseWithoutFixtures
  test 'exists? is false for obsolete term excluded from active lookup' do
    obsolete_term = CellOntologyTerm.find_by(identifier: 'EFO:0009310', original: true)
    skip 'EFO:0009310 obsolete term not loaded; run load_ontologies' unless obsolete_term&.obsolete?

    refute Scfair::OntologyLineageResolver.new.exists?('EFO:0009310')
  end

  test 'exists? is true for active replacement term' do
    skip 'EFO:0009899 not loaded; run load_ontologies' unless CellOntologyTerm.active_original_by_identifier('EFO:0009899')

    assert Scfair::OntologyLineageResolver.new.exists?('EFO:0009899')
  end
end
