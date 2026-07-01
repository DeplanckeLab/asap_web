# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairVarLegacySourceMatcherTest < TestBaseWithoutFixtures
  test 'suggests first matching legacy row_attrs name for feature_name' do
    Scfair::Rules.with_bundle('scfair_7_1_0') do
      assert_equal 'Gene',
                   Scfair::VarLegacySourceMatcher.suggest('feature_name', %w[_StableID Gene Accession])
      assert_nil Scfair::VarLegacySourceMatcher.suggest('feature_name', %w[_StableID Accession])
    end
  end

  test 'suggests legacy chromosome column names' do
    Scfair::Rules.with_bundle('scfair_7_1_0') do
      assert_equal 'chr',
                   Scfair::VarLegacySourceMatcher.suggest('feature_chromosome', %w[Gene chr])
    end
  end
end
