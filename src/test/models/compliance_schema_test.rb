# frozen_string_literal: true

require 'test_helper'

class ComplianceSchemaTest < ActiveSupport::TestCase
  setup do
    @schema = ComplianceSchema.create!(
      name: "scFAIR test #{SecureRandom.hex(3)}",
      version: '7.1.0',
      project_type_tags: 'sc',
      if_compliant: 'allow_public',
      active: true
    )
  end

  teardown do
    @schema&.destroy
  end

  test 'for_project_type matches comma-separated tags exactly' do
    @schema.update!(project_type_tags: 'sc,spat,atac,multi')

    %w[sc spat atac multi].each do |tag|
      assert_includes ComplianceSchema.for_project_type(tag).pluck(:id), @schema.id
    end
    assert_not_includes ComplianceSchema.for_project_type('bulk').pluck(:id), @schema.id
  end

  test 'ensure_sc_like_project_types! adds spat atac multi to scFAIR schemas' do
    others = ComplianceSchema.where.not(id: @schema.id).pluck(:id, :project_type_tags)
    @schema.update!(project_type_tags: 'sc')
    updated = ComplianceSchema.ensure_sc_like_project_types!

    assert updated >= 1
    assert_equal %w[sc spat atac multi], @schema.reload.tags
  ensure
    others&.each do |id, tags|
      ComplianceSchema.where(id: id).update_all(project_type_tags: tags)
    end
  end

  test 'spat atac and multi projects resolve the scFAIR schema' do
    @schema.update!(project_type_tags: 'sc,spat,atac,multi')
    user = register_for_test_cleanup(
      User.create!(email: "cschema_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )

    %w[spat atac multi].each do |tag|
      ptype = ProjectType.ensure_for_tag!(tag)
      project = create_test_project!(
        name: "#{tag} compliance",
        key: "#{tag[0, 2]}#{SecureRandom.hex(3)}",
        user_id: user.id,
        project_type_id: ptype.id
      )
      assert_includes project.compliance_schemas.pluck(:id), @schema.id, "expected #{tag} to get scFAIR"
      assert project.sc_like?
      assert project.compliance_requires_public?
    end
  end
end
