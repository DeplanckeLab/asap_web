class AddSlurmJobIdToRuns < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:runs)
    return if column_exists?(:runs, :slurm_job_id)
    
    add_column :runs, :slurm_job_id, :integer, null: true
    add_index :runs, :slurm_job_id, if_not_exists: true unless index_exists?(:runs, :slurm_job_id)
  end

  def down
    return unless table_exists?(:runs)
    return unless column_exists?(:runs, :slurm_job_id)
    
    remove_index :runs, :slurm_job_id if index_exists?(:runs, :slurm_job_id)
    remove_column :runs, :slurm_job_id
  end
end

