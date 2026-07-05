# frozen_string_literal: true

require_relative "../services/test_base_without_fixtures"

class FormAttrConstraintsTest < TestBaseWithoutFixtures
  test "input_data with min_nber_items 1 is required" do
    attr = { "widget" => "input_data", "min_nber_items" => 1 }
    assert FormAttrConstraints.required?("input_matrix", attr)
    refute FormAttrConstraints.optional?("input_matrix", attr)
    refute FormAttrConstraints.input_data_optional?(attr)
  end

  test "input_data with min_nber_items 0 is optional" do
    attr = { "widget" => "input_data", "min_nber_items" => 0 }
    refute FormAttrConstraints.required?("covariates", attr)
    assert FormAttrConstraints.optional?("covariates", attr)
    assert FormAttrConstraints.input_data_optional?(attr)
  end

  test "scalar uses not_null for required" do
    attr = { "widget" => "textfield", "not_null" => true }
    assert FormAttrConstraints.required?("perplexity", attr)
    refute FormAttrConstraints.optional?("perplexity", attr)
  end

  test "migrate_attr removes optional false on input_data and keeps min_nber_items" do
    migrated = FormAttrConstraints.migrate_attr!(
      "widget" => "input_data",
      "optional" => false,
      "min_nber_items" => 1
    )
    refute migrated.key?("optional")
    assert_equal 1, migrated["min_nber_items"]
  end

  test "migrate_attr converts optional true on input_data to min_nber_items 0" do
    migrated = FormAttrConstraints.migrate_attr!(
      "widget" => "input_data",
      "optional" => true
    )
    refute migrated.key?("optional")
    assert_equal 0, migrated["min_nber_items"]
  end

  test "migrate_attr converts optional on scalar to not_null" do
    migrated = FormAttrConstraints.migrate_attr!(
      "widget" => "textfield",
      "optional" => false
    )
    refute migrated.key?("optional")
    assert migrated["not_null"]
  end

  test "legacy optional false still treated as required until migrated" do
    attr = { "widget" => "input_data", "optional" => false }
    assert FormAttrConstraints.required?("input_matrix", attr)
  end
end
