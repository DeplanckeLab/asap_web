# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'

class GeneNcbiAltNamesPopulatorTest < TestBaseWithoutFixtures
  test 'build_gene_attributes collects NCBI symbol and external synonyms' do
    xrefs = {
      "1" => { acc: "7157", name: "TP53", type: "1300", description: "desc" },
      "2" => { acc: "123", name: "HGNC:11998", type: "1100", description: "desc" },
      "3" => { acc: "0", name: "TP53", type: "0", description: "desc" }
    }
    external_synonyms = { "2" => ["P53", "LFS1"] }
    object_xref_ids = %w[1 2]

    attrs = AsapData::GeneNcbiAltNamesPopulator.build_gene_attributes(
      "ENSG00000141510",
      "42",
      "3",
      object_xref_ids,
      xrefs,
      external_synonyms
    )

    assert_equal "TP53", attrs[:name]
    assert_equal 7157, attrs[:ncbi_gene_id]
    assert_equal %w[P53 LFS1], attrs[:alt_names]
  end

  test 'obsolete_alt_names_for_update moves retired symbols out of current names' do
    result = AsapData::GeneNcbiAltNamesPopulator.obsolete_alt_names_for_update(
      ["OLD_OBS"],
      %w[BRCC1 FANCS],
      "BRCA1",
      ["PPP1R53"],
      "BRCA1"
    )

    assert_includes result.split(","), "OLD_OBS"
    assert_includes result.split(","), "BRCC1"
    assert_includes result.split(","), "FANCS"
    refute_includes result.split(","), "BRCA1"
    refute_includes result.split(","), "PPP1R53"
  end

  test 'apply_release replays release-to-release renames like update_genes' do
    db_genes = {
      "ensg00000012048" => {
        id: 1,
        ensembl_id: "ENSG00000012048",
        name: "BRCA1",
        alt_names: "BRCC1,FANCS",
        obsolete_alt_names: "",
        ncbi_gene_id: nil,
        original: {
          name: "BRCA1",
          alt_names: "BRCC1,FANCS",
          obsolete_alt_names: "",
          ncbi_gene_id: nil
        },
        dirty: false
      }
    }

    release_one = {
      genes: {
        "ENSG00000012048" => { internal_id: "10", display_xref_id: "100" }
      },
      xrefs: {
        "100" => { acc: "0", name: "BRCA1", type: "0", description: "" },
        "101" => { acc: "672", name: "BRCA1", type: "1300", description: "" }
      },
      object_xrefs: { "10" => %w[101] },
      external_synonyms: {}
    }
    release_two = {
      genes: {
        "ENSG00000012048" => { internal_id: "10", display_xref_id: "200" }
      },
      xrefs: {
        "200" => { acc: "0", name: "BRCA1", type: "0", description: "" },
        "201" => { acc: "672", name: "BRCA1", type: "1300", description: "" },
        "202" => { acc: "0", name: "HGNC", type: "1100", description: "" }
      },
      object_xrefs: { "10" => %w[201 202] },
      external_synonyms: { "202" => ["BRCC1"] }
    }

    AsapData::GeneNcbiAltNamesPopulator.apply_release!(db_genes, release_one)
    AsapData::GeneNcbiAltNamesPopulator.apply_release!(db_genes, release_two)

    gene = db_genes["ensg00000012048"]
    assert_equal "BRCA1", gene[:name]
    assert_equal "BRCC1", gene[:alt_names]
    assert_includes gene[:obsolete_alt_names].split(","), "FANCS"
    assert gene[:dirty]
  end

  test 'parse_xrefs_filtered loads only requested xref rows' do
    Dir.mktmpdir do |tmpdir|
      path = File.join(tmpdir, "xref.txt")
      File.write(path, "1\t1300\t7157\tTP53\t0\tdesc\n2\t1100\t123\tHGNC\t0\tdesc\n")

      names = AsapData::GeneNcbiAltNamesPopulator.parse_xrefs_filtered(Pathname.new(path), Set["1"])

      assert_equal 1, names.size
      assert_equal "TP53", names["1"][:name]
    end
  end

  test 'parse_ncbi_xref_names keeps NCBI symbols from xref type 1300' do
    Dir.mktmpdir do |tmpdir|
      path = File.join(tmpdir, "xref.txt")
      File.write(path, "1\t1300\t7157\tTP53\t0\tdesc\n2\t1100\t123\tHGNC\t0\tdesc\n")

      names = AsapData::GeneNcbiAltNamesPopulator.parse_ncbi_xref_names(Pathname.new(path))

      assert_equal({ "1" => "TP53" }, names)
    end
  end
end
