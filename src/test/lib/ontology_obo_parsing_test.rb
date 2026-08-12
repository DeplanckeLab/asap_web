# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'

class OntologyOboParsingTest < TestBaseWithoutFixtures
  test 'xref with sssom annotation is stripped' do
    assert_equal 'ZFS:0100000', AsapData::OntologyOboParsing.normalize_multi_value('xref', 'ZFS:0100000')

    annotated = 'HsapDv:0000000 {sssom:mapping_justification="https://w3id.org/semapv/vocab/UnspecifiedMatching"}'
    assert_equal 'HsapDv:0000000', AsapData::OntologyOboParsing.normalize_multi_value('xref', annotated)
  end

  test 'is_a with inferred qualifier is stripped' do
    raw = 'CL:0002306 {is_inferred="true"}'
    assert_equal 'CL:0002306', AsapData::OntologyOboParsing.normalize_multi_value('is_a', raw)
  end

  test 'synonym qualifiers are preserved' do
    raw = '"developmental stage" EXACT []'
    assert_equal '"developmental stage" EXACT []', AsapData::OntologyOboParsing.normalize_multi_value('synonyms', raw)
  end
end
