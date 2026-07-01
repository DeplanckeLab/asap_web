# frozen_string_literal: true

class ReplaceGenesAltNamesBtreeIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    AsapData::GeneAltNamesIndexes.apply!(connection)
  end

  def down
    AsapData::GeneAltNamesIndexes.revert!(connection)
  end
end
