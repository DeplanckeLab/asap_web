# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRulesSnippetExtractorTest < TestBaseWithoutFixtures
  test 'extracts field constraint array entry with highlight' do
    result = Scfair::RulesSnippetExtractor.call('field_constraints.uns.ensembl_release.0')

    assert_nil result[:error]
    assert_equal 'field_constraints.uns.ensembl_release.0', result[:path]
    highlighted = result[:lines].select { |line| line[:highlight] }
    assert highlighted.any?
    assert highlighted.any? { |line| line[:text].include?('ensembl_release') || line[:text].include?('Requirement') }
  end

  test 'extracts ontology term format scalar' do
    result = Scfair::RulesSnippetExtractor.call('ontology_term_formats.obo.pattern')

    assert_nil result[:error]
    highlighted = result[:lines].select { |line| line[:highlight] }
    assert highlighted.any? { |line| line[:text].include?('pattern:') }
  end

  test 'extracts dotted by_field key paths' do
    result = Scfair::RulesSnippetExtractor.call('cross_field.validation.rules.CF-3.summary')

    assert_nil result[:error]
    highlighted = result[:lines].select { |line| line[:highlight] }
    assert highlighted.any? { |line| line[:text].include?('donor_id must not be "na"') }
  end

  test 'returns error for unknown path' do
    result = Scfair::RulesSnippetExtractor.call('missing.section.key')

    assert_equal 'Path not found: missing.section.key', result[:error]
  end

  test 'extracts required field list entry by array index' do
    result = Scfair::RulesSnippetExtractor.call('required.uns.5')

    assert_nil result[:error]
    highlighted = result[:lines].select { |line| line[:highlight] }
    assert highlighted.any? { |line| line[:text].include?('ensembl_release') }
  end

  test 'extracts presence_field_metadata extra_checks entry' do
    result = Scfair::RulesSnippetExtractor.call('presence_field_metadata.uns.ensembl_release.extra_checks.0')

    assert_nil result[:error]
    highlighted = result[:lines].select { |line| line[:highlight] }
    assert highlighted.any? { |line| line[:text].include?('positive integer Ensembl release number') }
  end

  test 'extracts label_pairs entry' do
    result = Scfair::RulesSnippetExtractor.call('label_pairs.sex_ontology_term_id')

    assert_nil result[:error]
    highlighted = result[:lines].select { |line| line[:highlight] }
    assert highlighted.any? { |line| line[:text].include?('sex') }
  end

  test 'extracts ontology_fields entry' do
    result = Scfair::RulesSnippetExtractor.call('ontology_fields.sex_ontology_term_id')

    assert_nil result[:error]
    highlighted = result[:lines].select { |line| line[:highlight] }
    assert highlighted.any? { |line| line[:text].include?('sex_ontology_term_id') }
  end
end
