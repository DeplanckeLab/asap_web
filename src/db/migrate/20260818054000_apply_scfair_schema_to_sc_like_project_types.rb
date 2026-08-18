# frozen_string_literal: true

class ApplyScfairSchemaToScLikeProjectTypes < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:compliance_schemas)

    ComplianceSchema.ensure_sc_like_project_types!
  end

  def down
    return unless table_exists?(:compliance_schemas)

    ComplianceSchema.find_each do |cs|
      tags = ComplianceSchema.parse_tags(cs.project_type_tags)
      next unless tags.include?('sc')

      cs.update!(project_type_tags: (tags - %w[spat atac multi]).join(','))
    end
  end
end
