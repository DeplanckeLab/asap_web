# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairFixFieldGroupRulesEnricherTest < TestBaseWithoutFixtures
  test 'injects allowed_terms from rules.yaml valid_terms' do
    groups = [{
      group: {
        id: 'sex',
        term_path: '/col_attrs/sex_ontology_term_id',
        term_ontology_prefixes: %w[PATO]
      }
    }]

    Scfair::FixFieldGroupRulesEnricher.call(groups)
    allowed = groups.first[:group][:allowed_terms]

    assert allowed.present?
    assert allowed.any? { |t| t[:identifier] == 'PATO:0000383' && t[:name] == 'female' }
  end

  test 'injects banned_term_ids from rules.yaml' do
    groups = [{
      group: {
        id: 'cell_type',
        term_path: '/col_attrs/cell_type_ontology_term_id',
        term_ontology_prefixes: %w[CL]
      }
    }]

    Scfair::FixFieldGroupRulesEnricher.call(groups)

    assert_includes groups.first[:group][:banned_term_ids], 'CL:0000003'
  end

  test 'injects multi_value flag from rules.yaml multi_value_fields' do
    groups = [{
      group: {
        id: 'disease',
        term_path: '/col_attrs/disease_ontology_term_id',
        label_path: '/col_attrs/disease'
      }
    }]

    Scfair::FixFieldGroupRulesEnricher.call(groups)

    assert groups.first[:group][:multi_value]
  end

  test 'injects multi_value_sorted for schema-sorted fields' do
    groups = [{
      group: {
        id: 'disease',
        term_path: '/col_attrs/disease_ontology_term_id',
        label_path: '/col_attrs/disease'
      }
    }]

    Scfair::FixFieldGroupRulesEnricher.call(groups)

    assert groups.first[:group][:multi_value_sorted]
  end

  test 'injects multi_value flag for cell_type from rules.yaml' do
    groups = [{
      group: {
        id: 'cell_type',
        term_path: '/col_attrs/cell_type_ontology_term_id',
        label_path: '/col_attrs/cell_type'
      }
    }]

    Scfair::FixFieldGroupRulesEnricher.call(groups)

    assert groups.first[:group][:multi_value]
    assert groups.first[:group][:multi_value_sorted]
  end

  test 'does not mark single-value fields as multi_value' do
    groups = [{
      group: {
        id: 'assay',
        term_path: '/col_attrs/assay_ontology_term_id',
        label_path: '/col_attrs/assay'
      }
    }]

    Scfair::FixFieldGroupRulesEnricher.call(groups)

    refute groups.first[:group][:multi_value]
  end

  test 'does not mark tissue as non-multi-value' do
    groups = [{
      group: {
        id: 'tissue',
        term_path: '/col_attrs/tissue_ontology_term_id',
        label_path: '/col_attrs/tissue'
      }
    }]

    Scfair::FixFieldGroupRulesEnricher.call(groups)

    assert groups.first[:group][:multi_value]
  end
end
