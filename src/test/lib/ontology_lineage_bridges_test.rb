# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'

class OntologyLineageBridgesTest < TestBaseWithoutFixtures
  test 'normalize_identifier strips sssom annotations' do
    raw = 'HsapDv:0000000 {sssom:mapping_justification="https://w3id.org/semapv/vocab/UnspecifiedMatching"}'
    assert_equal 'HsapDv:0000000', AsapData::OntologyLineageBridges.normalize_identifier(raw)
  end

  test 'outbound bridge uses xref when term has no native parent' do
    h_cot = {
      'xref' => ['UBERON:0000105'],
      'def' => '"life cycle stage" [UBERON:0000105]'
    }
    known = Set.new(%w[HsapDv:0000000 UBERON:0000105])

    bridges = AsapData::OntologyLineageBridges.outbound_bridge_terms(
      'HsapDv:0000000',
      h_cot,
      known,
      has_native_parent: false
    )

    assert_equal ['UBERON:0000105'], bridges
  end

  test 'outbound bridge skipped when native parent present' do
    h_cot = { 'xref' => ['UBERON:0000105'], 'is_a' => ['HsapDv:0000001'] }
    known = Set.new(%w[ZFS:0000032 UBERON:0000105 HsapDv:0000001])

    bridges = AsapData::OntologyLineageBridges.outbound_bridge_terms(
      'ZFS:0000032',
      h_cot,
      known,
      has_native_parent: true
    )

    assert_empty bridges
  end

  test 'reverse bridge from collected uberon xref to zfs root' do
    h_cot = {
      'xref' => [
        'HsapDv:0000000 {sssom:mapping_justification="https://w3id.org/semapv/vocab/UnspecifiedMatching"}',
        'ZFS:0000000',
        'ZFS:0100000',
        'WBls:0000002'
      ]
    }
    known = Set.new(%w[UBERON:0000105 ZFS:0100000 ZFS:0000000 WBls:0000002 HsapDv:0000000])

    targets = AsapData::OntologyLineageBridges.reverse_bridge_parent_for(
      'UBERON:0000105',
      h_cot,
      known
    )

    assert_includes targets, 'ZFS:0100000'
    assert_includes targets, 'ZFS:0000000'
    assert_includes targets, 'WBls:0000002'
    assert_includes targets, 'HsapDv:0000000'
  end

  test 'reverse bridge ignores timing relationships that mention stage terms' do
    h_cot = {
      'relationship' => {
        'existence_starts_during_or_after' => ['ZFS:0000032']
      }
    }
    known = Set.new(%w[ZFA:0000009 ZFS:0000032])

    targets = AsapData::OntologyLineageBridges.reverse_bridge_parent_for(
      'ZFA:0000009',
      h_cot,
      known
    )

    assert_empty targets
  end

  test 'reverse bridge ignores unknown and same-prefix targets' do
    h_cot = { 'xref' => %w[UBERON:0000104 MESH:D008018 ZFS:0100000] }
    known = Set.new(%w[UBERON:0000105 UBERON:0000104 ZFS:0100000])

    targets = AsapData::OntologyLineageBridges.reverse_bridge_parent_for(
      'UBERON:0000105',
      h_cot,
      known
    )

    assert_equal ['ZFS:0100000'], targets
  end
end
