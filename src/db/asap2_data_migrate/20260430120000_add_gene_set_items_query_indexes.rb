# frozen_string_literal: true

class AddGeneSetItemsQueryIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    AsapData::GeneSetItemsQueryIndexes.apply!(connection)
  end

  def down
    AsapData::GeneSetItemsQueryIndexes.revert!(connection)
  end
end
