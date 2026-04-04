# frozen_string_literal: true

class AddExcludeFromPageReplayToGuidedTourSteps < ActiveRecord::Migration[8.1]
  def change
    add_column :guided_tour_steps, :exclude_from_page_replay, :boolean, null: false, default: false
  end
end
