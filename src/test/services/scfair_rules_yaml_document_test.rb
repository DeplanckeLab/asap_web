# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRulesYamlDocumentTest < TestBaseWithoutFixtures
  test 'returns all rules yaml lines' do
    result = Scfair::RulesYamlDocument.call

    assert_equal Scfair::Rules.for('scfair_7_1_0').rules_relative_path, result[:file]
    assert_equal 'scfair_7_1_0', result[:schema_id]
    assert result[:lines].size > 1000
    assert result[:lines].first[:number] == 1
    assert result[:lines].first[:text].include?('scFAIR')
  end
end
