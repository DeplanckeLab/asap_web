class EnforceUniqueProjectSteps < ActiveRecord::Migration[7.2]
  def up
    duplicate_groups = execute(<<~SQL)
      SELECT project_id, step_id
      FROM project_steps
      GROUP BY project_id, step_id
      HAVING COUNT(*) > 1
    SQL

    duplicate_groups.each do |row|
      project_id = row["project_id"]
      step_id = row["step_id"]

      ids = execute(<<~SQL)
        SELECT id
        FROM project_steps
        WHERE project_id = #{project_id.to_i} AND step_id = #{step_id.to_i}
        ORDER BY id ASC
      SQL

      id_rows = ids.to_a
      keep_id = id_rows.last["id"].to_i
      delete_ids = id_rows.map { |r| r["id"].to_i } - [keep_id]
      next if delete_ids.empty?

      execute("DELETE FROM project_steps WHERE id IN (#{delete_ids.join(',')})")
    end

    add_index :project_steps, [:project_id, :step_id], unique: true, name: "index_project_steps_on_project_id_and_step_id"
  end

  def down
    remove_index :project_steps, name: "index_project_steps_on_project_id_and_step_id"
  end
end
