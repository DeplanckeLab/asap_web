# frozen_string_literal: true

namespace :reference_data do
  desc "Migrate deprecated optional to not_null / min_nber_items on Step.method_attrs_json and StdMethod.attrs_json"
  task migrate_optional_to_not_null: :environment do
    step_updates = 0
    std_method_updates = 0

    Step.find_each do |step|
      attrs = Basic.safe_parse_json(step.method_attrs_json, {})
      next if attrs.empty?

      migrated = FormAttrConstraints.migrate_attrs_hash!(attrs)
      next if migrated.to_json == attrs.to_json

      step.update!(method_attrs_json: JSON.pretty_generate(migrated))
      step_updates += 1
      puts "Updated step #{step.id} (#{step.name})"
    end

    StdMethod.find_each do |std_method|
      attrs = Basic.safe_parse_json(std_method.attrs_json, {})
      next if attrs.empty?

      migrated = FormAttrConstraints.migrate_attrs_hash!(attrs)
      next if migrated.to_json == attrs.to_json

      std_method.update!(attrs_json: JSON.pretty_generate(migrated))
      std_method_updates += 1
      puts "Updated std_method #{std_method.id} (#{std_method.name})"
    end

    puts "Done: #{step_updates} step(s), #{std_method_updates} std_method(s) updated"
  end
end
