# frozen_string_literal: true

module Scfair
  class RulesYamlDocument
    def self.call
      lines = File.readlines(Rules::RULES_PATH).map.with_index(1) do |line, number|
        { number: number, text: line.rstrip }
      end

      {
        file: 'config/scfair/7.1.0/rules.yaml',
        lines: lines
      }
    end
  end
end
