# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairFixFormFieldGroupsBuilderTest < TestBaseWithoutFixtures
  test 'loads all fix_form field groups from rules.yaml' do
    groups = Scfair::FixFormFieldGroupsBuilder.call

    assert_equal 25, groups.size
    ids = groups.map { |g| g[:id] }
    assert_includes ids, 'assay'
    assert_includes ids, 'schema_version'
    assert_includes ids, 'is_primary_data'
  end

  test 'builds paired ontology group with paths and prefixes from rules' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    assay = groups.find { |g| g[:id] == 'assay' }

    assert_equal 'Assay', assay[:label]
    assert_equal '/col_attrs/assay_ontology_term_id', assay[:term_path]
    assert_equal '/col_attrs/assay', assay[:label_path]
    assert_equal %w[EFO], assay[:term_ontology_prefixes]
    assert_equal :ontology_pair, assay[:field_kind]
    refute assay[:multi_value]
  end

  test 'builds enum group with values from enum_fields' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    tissue_type = groups.find { |g| g[:id] == 'tissue_type' }

    assert_equal :enum, tissue_type[:field_kind]
    assert_equal ['cell line', 'organoid', 'primary cell culture', 'tissue'].sort,
                 tissue_type[:term_valid_values].sort
  end

  test 'builds boolean group with allowed_values from fix_form' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    is_primary = groups.find { |g| g[:id] == 'is_primary_data' }

    assert_equal :boolean, is_primary[:field_kind]
    assert_equal %w[True False], is_primary[:term_valid_values]
  end

  test 'builds auto_fill global attrs' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    schema_version = groups.find { |g| g[:id] == 'schema_version' }

    assert_equal :global_attr, schema_version[:type]
    assert_equal :schema_version, schema_version[:auto_from_project]
    assert_equal '/attrs/schema_version', schema_version[:term_path]
  end

  test 'builds ensembl auto_fill global attrs without enum values' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    ensembl_release = groups.find { |g| g[:id] == 'ensembl_release' }
    ensembl_database = groups.find { |g| g[:id] == 'ensembl_database' }
    ensembl_assembly = groups.find { |g| g[:id] == 'ensembl_assembly' }

    assert_equal :auto_fill, ensembl_release[:field_kind]
    assert_equal :ensembl_release, ensembl_release[:auto_from_project]
    refute ensembl_release.key?(:term_valid_values)

    assert_equal :ensembl_database, ensembl_database[:auto_from_project]
    refute ensembl_database.key?(:term_valid_values)

    assert_equal :ensembl_assembly, ensembl_assembly[:auto_from_project]
    refute ensembl_assembly.key?(:term_valid_values)
  end

  test 'enriches sex with allowed_terms from ontology_fields valid_terms' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    sex = groups.find { |g| g[:id] == 'sex' }

    assert sex[:allowed_terms].present?
    assert sex[:allowed_terms].any? { |t| t[:identifier] == 'PATO:0000383' }
  end

  test 'Rules.fix_form_field_groups delegates to builder' do
    groups = Scfair::Rules.fix_form_field_groups

    assert_equal 25, groups.size
    assert groups.first[:id].present?
  end

  test 'Rules.fix_form_auto_fill_value returns schema constants' do
    Scfair::Rules.with_bundle('scfair_7_1_0') do
      assert_equal Scfair::Rules.schema_hash[:schema_version],
                   Scfair::Rules.fix_form_auto_fill_value('schema_version')
      assert_equal Scfair::Rules.schema_hash[:source_url],
                   Scfair::Rules.fix_form_auto_fill_value('schema_reference')
    end
  end

  test 'builds var row_attr groups with loom paths' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    feature_name = groups.find { |g| g[:id] == 'feature_name' }

    assert_equal :row_attr, feature_name[:type]
    assert_equal '/row_attrs/feature_name', feature_name[:term_path]
    assert_equal :free_text, feature_name[:field_kind]
  end

  test 'builds var enum and boolean groups' do
    groups = Scfair::FixFormFieldGroupsBuilder.call
    biotype = groups.find { |g| g[:id] == 'feature_biotype' }
    filtered = groups.find { |g| g[:id] == 'feature_is_filtered' }

    assert_equal %w[gene spike-in].sort, biotype[:term_valid_values].sort
    assert_equal %w[false true], filtered[:term_valid_values]
  end

  test 'Rules.fix_form_var_legacy_sources loads from rules.yaml' do
    Scfair::Rules.with_bundle('scfair_7_1_0') do
      sources = Scfair::Rules.fix_form_var_legacy_sources
      assert_includes sources['feature_name'], 'Gene'
      assert_includes sources['feature_chromosome'], 'chr'
    end
  end

  test 'attaches ontology_term_type_id only for ontology_pair field kinds' do
    groups = Scfair::FixFormFieldGroupsBuilder.call(
      ontology_term_type_id_map: { 'assay' => 7, 'tissue_type' => 11 }
    )
    assay = groups.find { |g| g[:id] == 'assay' }
    tissue_type = groups.find { |g| g[:id] == 'tissue_type' }

    assert_equal 7, assay[:ontology_term_type_id]
    refute tissue_type.key?(:ontology_term_type_id)
  end
end
