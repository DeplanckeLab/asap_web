# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'
require 'tmpdir'
require 'fileutils'

class EnsemblCovidLoaderTest < TestBaseWithoutFixtures
  SAMPLE_GTF = <<~GTF.freeze
    MN908947.3	ensembl	gene	266	21555	.	+	.	gene_id "ENSSASG00005000002"; gene_version "1"; gene_name "ORF1ab"; gene_source "ensembl"; gene_biotype "protein_coding";
    MN908947.3	ensembl	gene	21563	25384	.	+	.	gene_id "ENSSASG00005000004"; gene_version "1"; gene_name "S"; gene_source "ensembl"; gene_biotype "protein_coding";
  GTF

  SAMPLE_ENTREZ = <<~TSV.freeze
    gene_stable_id	transcript_stable_id	protein_stable_id	xref	db_name	info_type	source_identity	xref_identity	linkage_type
    ENSSASG00005000002	ENSSAST00005000002	ENSSASP00005000002	43740578	EntrezGene	DEPENDENT	-	-	-
    ENSSASG00005000004	ENSSAST00005000004	ENSSASP00005000004	43740568	EntrezGene	DEPENDENT	-	-	-
    ENSSASG00005000004	ENSSAST00005000004	ENSSASP00005000004	S	EntrezGene_trans_name	MISC	-	-	-
  TSV

  SAMPLE_REFSEQ = <<~TSV.freeze
    gene_stable_id	transcript_stable_id	protein_stable_id	xref	db_name	info_type	source_identity	xref_identity	linkage_type
    ENSSASG00005000004	ENSSAST00005000004	ENSSASP00005000004	YP_009724390	RefSeq_peptide	SEQUENCE_MATCH	100	100	-
  TSV

  test 'parse_genes_from_gtf extracts stable ids names and lengths' do
    with_tmp_file(SAMPLE_GTF, "genes.gtf") do |path|
      genes = AsapData::EnsemblCovidLoader.parse_genes_from_gtf(path)

      assert_equal 2, genes.size
      assert_equal "ORF1ab", genes["ENSSASG00005000002"][:name]
      assert_equal "protein_coding", genes["ENSSASG00005000002"][:biotype]
      assert_equal "MN908947.3", genes["ENSSASG00005000002"][:chr]
      assert_equal 21_290, genes["ENSSASG00005000002"][:gene_length]
    end
  end

  test 'build_gene_records merges entrez and refseq xrefs' do
    with_tmp_file(SAMPLE_GTF, "genes.gtf") do |gtf_path|
      with_tmp_file(SAMPLE_ENTREZ, "entrez.tsv") do |entrez_path|
        with_tmp_file(SAMPLE_REFSEQ, "refseq.tsv") do |refseq_path|
          genes = AsapData::EnsemblCovidLoader.parse_genes_from_gtf(gtf_path)
          entrez = AsapData::EnsemblCovidLoader.parse_entrez_xrefs(entrez_path)
          refseq = AsapData::EnsemblCovidLoader.parse_refseq_xrefs(refseq_path)
          records = AsapData::EnsemblCovidLoader.build_gene_records(genes, entrez, refseq)

          spike = records.find { |row| row[:ensembl_id] == "ENSSASG00005000004" }
          assert_equal "S", spike[:name]
          assert_equal 43_740_568, spike[:ncbi_gene_id]
          assert_includes spike[:alt_names].split(","), "YP_009724390"
          assert_equal AsapData::EnsemblCovidLoader::RELEASE, spike[:latest_ensembl_release]
        end
      end
    end
  end

  test 'gene_names_from_gtf returns requested stable id names' do
    with_tmp_file(SAMPLE_GTF, "genes.gtf") do |path|
      names = AsapData::EnsemblCovidLoader.gene_names_from_gtf(path, %w[ENSSASG00005000004 ENSSASG00005000099])

      assert_equal({ "ENSSASG00005000004" => "S" }, names)
    end
  end

  private

  def with_tmp_file(content, filename)
    Dir.mktmpdir("covid_loader_test") do |dir|
      path = Pathname.new(dir) + filename
      path.write(content)
      yield path
    end
  end
end
