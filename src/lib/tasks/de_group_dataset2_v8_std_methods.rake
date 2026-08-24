# frozen_string_literal: true

namespace :de_group_dataset2_v8_std_methods do
  desc 'Fix --group-dataset-2 to use groups2_dataset on v8 DE Step and StdMethods'
  task upsert: :environment do
    require_relative '../de_group_dataset2_v8_std_methods'
    summary = DeGroupDataset2V8StdMethods.upsert!
    puts summary.inspect
  end
end
