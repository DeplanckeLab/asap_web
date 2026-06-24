# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairRulesRegistryTest < TestBaseWithoutFixtures
  test 'discovers default scfair 7.1.0 bundle' do
    entry = Scfair::RulesRegistry.entry_for('scfair_7_1_0')

    assert_equal 'scfair_7_1_0', entry.id
    assert_equal '7.1.0', entry.version
    assert entry.path.exist?
  end

  test 'for returns bundle with matching schema id' do
    bundle = Scfair::Rules.for('scfair_7_1_0')

    assert_equal 'scfair_7_1_0', bundle.registry_schema_id
    assert_equal '7.1.0', bundle.schema_version
    assert bundle.checks_for('loom').any?
  end

  test 'unknown schema raises' do
    assert_raises(ArgumentError) do
      Scfair::Rules.for('scfair_9_9_9')
    end
  end

  test 'available_schemas lists discovered releases' do
    schemas = Scfair::Rules.available_schemas

    assert schemas.any? { |s| s[:id] == 'scfair_7_1_0' }
    assert schemas.first[:label].present?
  end

  test 'with_bundle scopes module delegation' do
    Scfair::Rules.with_bundle('scfair_7_1_0') do
      assert_equal '7.1.0', Scfair::Rules.schema_version
    end
  end
end
