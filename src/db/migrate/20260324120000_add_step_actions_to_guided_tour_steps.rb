class AddStepActionsToGuidedTourSteps < ActiveRecord::Migration[8.1]
  def change
    add_column :guided_tour_steps, :step_actions, :jsonb, null: false, default: []
  end
end
