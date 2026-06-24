# frozen_string_literal: true

module Scfair
  class RulesYamlDocument
    def self.call(schema_id: nil)
      bundle = Rules.for(schema_id)
      lines = File.readlines(bundle.rules_path.to_s).map.with_index(1) do |line, number|
        { number: number, text: line.rstrip }
      end

      {
        file: bundle.rules_relative_path,
        schema_id: bundle.registry_schema_id,
        lines: lines
      }
    end
  end
end
