class ChangeDelRunsPredMaxRamToBigint < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:del_runs)
    return unless column_exists?(:del_runs, :pred_max_ram)

    change_column :del_runs, :pred_max_ram, :bigint
  end

  def down
    return unless table_exists?(:del_runs)
    return unless column_exists?(:del_runs, :pred_max_ram)

    change_column :del_runs, :pred_max_ram, :integer
  end
end
