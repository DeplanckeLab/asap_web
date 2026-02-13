class AddFieldGroupIdToOntologyTermTypes < ActiveRecord::Migration[7.2]
  def up
    # Column may already exist from a prior partial run
    execute "ALTER TABLE ontology_term_types ADD COLUMN IF NOT EXISTS field_group_id text"

    mapping = {
      'cell_type'          => 'cell_type',
      'tissue'             => 'tissue',
      'developmental_stage' => 'development_stage',
      'disease'            => 'disease',
      'sex'                => 'sex',
      'ethnicity'          => 'self_reported_ethnicity',
      'technology'         => 'assay'
    }

    mapping.each do |ott_name, fg_id|
      execute "UPDATE ontology_term_types SET field_group_id = #{connection.quote(fg_id)} WHERE name = #{connection.quote(ott_name)}"
    end
  end

  def down
    execute "ALTER TABLE ontology_term_types DROP COLUMN IF EXISTS field_group_id"
  end
end
