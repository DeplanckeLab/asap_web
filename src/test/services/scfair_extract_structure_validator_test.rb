# frozen_string_literal: true

require 'test_helper'

class ScfairExtractStructureValidatorTest < ActiveSupport::TestCase
  test 'warns with explicit obs column missing from column-order attribute' do
    extract = {
      'file_inventory' => {
        'structure' => { 'groups_present' => %w[obs var X] },
        'matrix' => { 'n_obs' => 10, 'n_vars' => 100 },
        'obs' => {
          'column_names' => %w[CellID organism],
          'declared_column_names' => %w[organism]
        }
      }
    }

    result = Scfair::ExtractStructureValidator.new(extract: extract, format: 'h5ad').call

    assert_equal 1, result[:warnings].size
    assert_match(/The obs column CellID is stored in the file but not listed in the obs column-order attribute/, result[:warnings].first[:message])
    refute_match(/e\.g\./, result[:warnings].first[:message])
  end

  test 'warns with all obs columns missing from column-order attribute' do
    extract = {
      'file_inventory' => {
        'structure' => { 'groups_present' => %w[obs var X] },
        'matrix' => { 'n_obs' => 10, 'n_vars' => 100 },
        'obs' => {
          'column_names' => %w[CellID organism assay],
          'declared_column_names' => %w[organism]
        }
      }
    }

    result = Scfair::ExtractStructureValidator.new(extract: extract, format: 'h5ad').call

    assert_equal 1, result[:warnings].size
    assert_match(/The obs columns CellID, assay are stored in the file/, result[:warnings].first[:message])
  end

  test 'errors when column-order lists obs columns not stored in the file' do
    extract = {
      'file_inventory' => {
        'structure' => { 'groups_present' => %w[obs var X] },
        'matrix' => { 'n_obs' => 10, 'n_vars' => 100 },
        'obs' => {
          'column_names' => %w[organism],
          'declared_column_names' => %w[CellID organism]
        }
      }
    }

    result = Scfair::ExtractStructureValidator.new(extract: extract, format: 'h5ad').call

    assert_equal 1, result[:errors].size
    assert_match(/The obs column-order attribute lists CellID, which is not stored in the file/, result[:errors].first[:message])
  end

  test 'standalone loom validation omits missing anndata_mapping warning' do
    result = Scfair::ExtractStructureValidator.new(
      extract: loom_extract(anndata_mapping_present: false),
      format: 'loom',
      project_compliance: false
    ).call

    refute result[:warnings].any? { |w| w[:field] == '/attrs/anndata_mapping' }
  end

  test 'project loom validation warns when anndata_mapping is missing' do
    result = Scfair::ExtractStructureValidator.new(
      extract: loom_extract(anndata_mapping_present: false),
      format: 'loom',
      project_compliance: true
    ).call

    warning = result[:warnings].find { |w| w[:field] == '/attrs/anndata_mapping' }
    assert warning
    assert_match(/Missing anndata_mapping manifest/, warning[:message])
    assert_match(/before validation, download, and H5AD export/, warning[:message])
    refute_match(/recommended for deterministic Loom->H5AD conversion/, warning[:message])
  end

  private

  def loom_extract(anndata_mapping_present:)
    {
      'file_inventory' => {
        'structure' => {
          'groups_present' => %w[matrix col_attrs row_attrs attrs],
          'anndata_mapping_present' => anndata_mapping_present
        },
        'matrix' => { 'n_obs' => 10, 'n_vars' => 100 },
        'obs' => { 'column_names' => %w[CellID] }
      }
    }
  end
end
