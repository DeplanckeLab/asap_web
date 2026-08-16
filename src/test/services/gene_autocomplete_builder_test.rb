# frozen_string_literal: true

require "test_helper"

class GeneAutocompleteBuilderTest < ActiveSupport::TestCase
  test "builds search lines and empty aliases without organism or db" do
    payload = GeneAutocompleteBuilder.build(
      gene_values: %w[TP53 GAPDH],
      accession_values: %w[ENSG00000141510 ENSG00000111640],
      stable_values: %w[1 2],
      feature_name_values: %w[TP53 GAPDH],
      ensembl_release: 101,
      organism_id: nil,
      db_version: nil
    )

    assert_equal GeneAutocompleteBuilder::SCHEMA_VERSION, payload["schema_version"]
    assert_equal 2, payload["search"].length
    assert_includes payload["search"], "TP53 ENSG00000141510 {1}"
    assert_equal({}, payload["aliases"])
    assert_equal({ "1" => "TP53", "2" => "GAPDH" }, payload["feature_names"])
    assert_equal 101, payload["ensembl_release"]
    assert GeneAutocompleteBuilder.usable_cached_payload?(payload)
  end

  test "alias_tokens splits csv json and pg array shapes" do
    assert_equal %w[A B], GeneAutocompleteBuilder.alias_tokens("A, B")
    assert_equal %w[A B], GeneAutocompleteBuilder.alias_tokens('["A","B"]')
    assert_equal %w[A B], GeneAutocompleteBuilder.alias_tokens("{A,B}")
  end

  test "usable_cached_payload rejects legacy caches" do
    refute GeneAutocompleteBuilder.usable_cached_payload?("search" => ["TP53 ENSG1 {1}"], "h_indexes" => {})
    refute GeneAutocompleteBuilder.usable_cached_payload?(
      "schema_version" => 2,
      "search" => ["TP53 ENSG1 {1}"],
      "aliases" => {},
      "feature_names" => {}
    )
  end
end
