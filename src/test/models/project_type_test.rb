# frozen_string_literal: true

require 'test_helper'

class ProjectTypeTest < ActiveSupport::TestCase
  test 'ensure_for_tag! creates spat when missing' do
    existing = ProjectType.find_by(tag: 'spat')
    existing&.destroy!

    record = ProjectType.ensure_for_tag!('spat')
    assert_equal 'spat', record.tag
    assert_equal 'Spatial transcriptomics', record.name
    assert_equal 'genes', record.row_label
    assert_equal 'cells', record.col_label
  ensure
    ProjectType.ensure_for_tag!('spat')
  end

  test 'ensure_for_tag! creates all canonical tags' do
    ProjectType::CANONICAL.each_key do |tag|
      record = ProjectType.ensure_for_tag!(tag)
      assert_equal tag, record.tag
      assert_equal ProjectType::CANONICAL[tag][:name], record.name
    end
  end

  test 'ensure_for_tag! returns existing row without changing tag' do
    existing = ProjectType.ensure_for_tag!('sc')
    again = ProjectType.ensure_for_tag!('sc')
    assert_equal existing.id, again.id
  end

  test 'sc_like? is true for sc spat atac multi and false for bulk' do
    %w[sc spat atac multi].each do |tag|
      assert ProjectType.ensure_for_tag!(tag).sc_like?, "expected #{tag} to be sc-like"
    end
    refute ProjectType.ensure_for_tag!('bulk').sc_like?
  end
end
