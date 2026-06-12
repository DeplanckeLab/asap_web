# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRulesYamlDocumentTest < TestBaseWithoutFixtures
  test 'returns all rules yaml lines' do
    result = Scfair::RulesYamlDocument.call

    assert_equal 'config/scfair/7.1.0/rules.yaml', result[:file]
    assert result[:lines].size > 1000
    assert result[:lines].first[:number] == 1
    assert result[:lines].first[:text].include?('scFAIR')
  end
end
