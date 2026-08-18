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
    assert record.admin_report_only?
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

  test 'ensure_for_tag! does not overwrite admin_report_only on existing rows' do
    record = ProjectType.ensure_for_tag!('spat')
    record.update!(admin_report_only: false)

    again = ProjectType.ensure_for_tag!('spat')
    refute again.reload.admin_report_only?
  ensure
    ProjectType.find_by(tag: 'spat')&.update!(admin_report_only: true)
  end

  test 'selectable_for excludes admin_report_only types unless include_restricted' do
    spat = ProjectType.ensure_for_tag!('spat')
    sc = ProjectType.ensure_for_tag!('sc')
    spat.update!(admin_report_only: true)
    sc.update!(admin_report_only: false)

    public_tags = ProjectType.selectable_for(include_restricted: false).pluck(:tag)
    refute_includes public_tags, 'spat'
    assert_includes public_tags, 'sc'

    all_tags = ProjectType.selectable_for(include_restricted: true).pluck(:tag)
    assert_includes all_tags, 'spat'
    assert_includes all_tags, 'sc'
  ensure
    ProjectType.find_by(tag: 'spat')&.update!(admin_report_only: true)
    ProjectType.find_by(tag: 'sc')&.update!(admin_report_only: false)
  end
end
