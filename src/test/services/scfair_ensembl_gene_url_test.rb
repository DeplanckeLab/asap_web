# frozen_string_literal: true

require 'test_helper'

class ScfairEnsemblGeneUrlTest < ActiveSupport::TestCase
  test 'builds genome-browser url from assembly and gene id' do
    url = Scfair::EnsemblGeneUrl.build(
      ensembl_id: 'AAEL004591',
      assembly: 'GCA_002204515.1'
    )
    assert_equal 'https://www.ensembl.org/genome-browser/GCA_002204515.1?focus=gene:AAEL004591', url
  end

  test 'strips version suffix from ensembl id' do
    url = Scfair::EnsemblGeneUrl.build(
      ensembl_id: 'ENSG00000139618.15',
      assembly: 'GRCh38.p14'
    )
    assert_equal 'https://www.ensembl.org/genome-browser/GRCh38.p14?focus=gene:ENSG00000139618', url
  end

  test 'returns nil without assembly or gene id' do
    assert_nil Scfair::EnsemblGeneUrl.build(ensembl_id: 'AAEL004591', assembly: nil)
    assert_nil Scfair::EnsemblGeneUrl.build(ensembl_id: '', assembly: 'GCA_002204515.1')
  end
end
