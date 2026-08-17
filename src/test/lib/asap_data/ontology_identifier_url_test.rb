# frozen_string_literal: true

require_relative "../../services/test_base_without_fixtures"

class OntologyIdentifierUrlTest < TestBaseWithoutFixtures
  test "builds EFO term urls from url_mask" do
    efo = CellOntology.find_by(tag: "EFO")
    skip "EFO CellOntology with url_mask is required" unless efo&.url_mask.to_s.strip.present?

    url = AsapData::OntologyIdentifierUrl.url_for("EFO:0030007")
    assert_match(%r{\Ahttps?://}, url.to_s)
    assert_includes url, "EFO_0030007"
  end
end
