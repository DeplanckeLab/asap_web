# frozen_string_literal: true

namespace :de_cell_universe_v8_std_methods do
  desc 'Add --cell-universe-file / --cell-universe-mode opts to v8 DE StdMethods (de.v8.py / de_approx.v8.py)'
  task upsert: :environment do
    require_relative '../de_cell_universe_v8_std_methods'
    summary = DeCellUniverseV8StdMethods.upsert!
    puts summary.inspect
  end
end
