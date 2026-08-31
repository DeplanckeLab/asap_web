# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairFixFormCrossFieldConstraintsTest < TestBaseWithoutFixtures
  def fixable_groups
    [
      {
        group: {
          id: 'self_reported_ethnicity',
          term_path: '/col_attrs/self_reported_ethnicity_ontology_term_id',
          label_path: '/col_attrs/self_reported_ethnicity'
        }
      },
      {
        group: {
          id: 'sex',
          term_path: '/col_attrs/sex_ontology_term_id',
          label_path: '/col_attrs/sex'
        }
      },
      {
        group: {
          id: 'development_stage',
          term_path: '/col_attrs/development_stage_ontology_term_id',
          label_path: '/col_attrs/development_stage'
        }
      },
      { group: { id: 'donor_id', term_path: '/col_attrs/donor_id' } },
      { group: { id: 'suspension_type', term_path: '/col_attrs/suspension_type' } },
      {
        group: {
          id: 'cell_type',
          term_path: '/col_attrs/cell_type_ontology_term_id',
          label_path: '/col_attrs/cell_type'
        }
      },
      {
        group: {
          id: 'disease',
          term_path: '/col_attrs/disease_ontology_term_id',
          label_path: '/col_attrs/disease'
        }
      },
      {
        group: {
          id: 'tissue',
          term_path: '/col_attrs/tissue_ontology_term_id',
          label_path: '/col_attrs/tissue'
        }
      }
    ]
  end

  test 'static constraint forces ethnicity to na for non-human organism' do
    organism = Struct.new(:tax_id, :name).new(10090, 'Mus musculus')
    project = Struct.new(:organism).new(organism)

    config = Scfair::FixFormCrossFieldConstraints.build(project: project, fixable_groups: fixable_groups)
    constraint = config.dig('static', 'self_reported_ethnicity')

    assert constraint.present?
    assert_equal 'na', constraint['forced_term_value']
    assert_equal 'na', constraint['forced_label_value']
    assert_includes constraint['reason'], 'Mus musculus'
    assert_includes constraint['reason'], Scfair::Rules.organism_specific_display_constraint(:non_human_ethnicity)
  end

  test 'no static constraint for human organism' do
    organism = Struct.new(:tax_id, :name).new(9606, 'Homo sapiens')
    project = Struct.new(:organism).new(organism)

    config = Scfair::FixFormCrossFieldConstraints.build(project: project, fixable_groups: fixable_groups)

    assert_equal({}, config['static'])
  end

  test 'cell line config is built from rules.yaml cell_line_forced_fields' do
    project = Struct.new(:organism).new(nil)

    config = Scfair::FixFormCrossFieldConstraints.build(project: project, fixable_groups: fixable_groups)
    cell_line = config['cell_line']

    assert_equal Scfair::Rules.tissue_type_cell_line_value, cell_line['trigger_value']
    assert_equal 'tissue_type is "cell line".', cell_line['reason']

    forced = cell_line['forced_fields']
    assert_equal 5, forced.size

    ethnicity = forced.find { |f| f['group_id'] == 'self_reported_ethnicity' }
    assert_equal 'na', ethnicity['term_value']
    assert_equal '/col_attrs/self_reported_ethnicity', ethnicity['label_path']
    assert_equal 'na', ethnicity['label_value']

    dev_stage = forced.find { |f| f['group_id'] == 'development_stage' }
    assert_equal 'na', dev_stage['term_value']
    assert_equal 'na', dev_stage['label_value']

    assert_includes cell_line['affected_group_ids'], 'tissue'
    assert_includes cell_line['tissue_note']['detail'], 'Cellosaurus'
  end

  test 'includes multi_value config from rules.yaml' do
    project = Struct.new(:organism).new(nil)

    config = Scfair::FixFormCrossFieldConstraints.build(project: project, fixable_groups: fixable_groups)
    multi = config['multi_value']

    assert_equal Scfair::Rules.multi_value_delimiter, multi['delimiter']
    assert_equal ' || ', multi['delimiter']
    assert multi['requirement'].present?
    assert multi['by_group_id']['self_reported_ethnicity'].present?
    assert_equal 'self_reported_ethnicity_ontology_term_id', multi['by_group_id']['self_reported_ethnicity']['obs_field']
    assert multi['by_group_id']['self_reported_ethnicity']['sorted']
    assert multi['by_group_id']['tissue'].present?
    assert multi['by_group_id']['disease'].present?
    assert multi['by_group_id']['cell_type'].present?
    assert multi['by_group_id']['development_stage'].present?
    assert_equal 'development_stage_ontology_term_id', multi['by_group_id']['development_stage']['obs_field']
    assert multi['by_group_id']['development_stage']['sorted']
    assert_equal 'cell_type_ontology_term_id', multi['by_group_id']['cell_type']['obs_field']
  end

  test 'assay suspension config includes map and messages from rules.yaml' do
    project = Struct.new(:organism).new(nil)

    config = Scfair::FixFormCrossFieldConstraints.build(project: project, fixable_groups: fixable_groups)
    susp = config['assay_suspension']

    assert_equal Scfair::Rules.assay_suspension_type_map, susp['map']
    assert_equal Scfair::Rules.assay_ancestor_terms, susp['ancestor_terms']
    assert_equal 'suspension_type', susp['group_id']
    assert_equal '/col_attrs/suspension_type', susp['term_path']
    assert_includes susp['lock_reason_template'], '%{assay}'
  end

  test 'tissue_type_tissue config excludes cellosaurus for default tissue prefixes' do
    organism = Struct.new(:tax_id, :name).new(9606, 'Homo sapiens')
    project = Struct.new(:organism).new(organism)

    config = Scfair::FixFormCrossFieldConstraints.build(project: project, fixable_groups: fixable_groups)
    tissue_cfg = config['tissue_type_tissue']

    assert_equal 'tissue', tissue_cfg['group_id']
    assert_equal 'tissue_type', tissue_cfg['trigger_group_id']
    assert_equal Scfair::Rules.organism_specific_validation_config[:cell_line_tissue_type], tissue_cfg['cell_line_value']
    assert_equal ['CVCL'], tissue_cfg['cell_line_prefixes']
    assert_equal Scfair::Rules.organism_tissue_prefixes_for('NCBITaxon:9606'), tissue_cfg['tissue_prefixes']
    refute_includes tissue_cfg['tissue_prefixes'], 'CVCL'
    assert_equal Scfair::Rules.organism_cell_type_prefixes_for('NCBITaxon:9606'), tissue_cfg['cell_type_prefixes']
  end
end
