# frozen_string_literal: true

module Scfair
  # Returns a contextual excerpt from rules.yaml for a dot-separated rules_path
  # (e.g. field_constraints.uns.ensembl_release.0).
  class RulesSnippetExtractor
    CONTEXT_LINES = 2

    def self.call(rules_path)
      new(rules_path).call
    end

    def initialize(rules_path)
      @parts = rules_path.to_s.split('.')
      @lines = File.readlines(Rules::RULES_PATH, chomp: false)
    end

    def call
      return error_result('Missing rules path') if @parts.empty?

      anchor_idx = locate_node
      return error_result("Path not found: #{@parts.join('.')}") if anchor_idx.nil?

      highlight_start, highlight_end = block_range(anchor_idx)
      context_start = [highlight_start - CONTEXT_LINES, 1].max
      context_end = [highlight_end + CONTEXT_LINES, @lines.size].min

      {
        path: @parts.join('.'),
        file: 'config/scfair/7.1.0/rules.yaml',
        highlight_start: highlight_start,
        highlight_end: highlight_end,
        lines: (context_start..context_end).map do |line_number|
          {
            number: line_number,
            text: @lines[line_number - 1].rstrip,
            highlight: line_number >= highlight_start && line_number <= highlight_end
          }
        end
      }
    end

    private

    def error_result(message)
      { error: message }
    end

    def locate_node
      search_from = 0
      parent_indent = -1
      part_idx = 0

      while part_idx < @parts.size
        part = @parts[part_idx]
        if part.match?(/\A\d+\z/)
          search_from = find_array_item(search_from, parent_indent, part.to_i)
          return nil if search_from.nil?

          parent_indent = line_indent(search_from)
          search_from += 1
          part_idx += 1
          next
        end

        matched = false
        (@parts.size - part_idx).downto(1) do |len|
          composite = @parts[part_idx, len].join('.')
          found = find_child_key(search_from, parent_indent, composite)
          next unless found

          search_from = found
          parent_indent = line_indent(search_from)
          search_from += 1
          part_idx += len
          matched = true
          break
        end
        return nil unless matched
      end

      search_from - 1
    end

    def find_child_key(from_idx, parent_indent, key)
      (from_idx...@lines.size).each do |i|
        line = @lines[i]
        next if line.strip.empty?

        indent = line_indent(i)
        break if indent <= parent_indent && i > from_idx

        match = line.match(/^(\s*)#{Regexp.escape(key)}:(?:\s|$)/)
        next unless match
        next unless match[1].length > parent_indent

        return i
      end
      nil
    end

    def find_array_item(from_idx, parent_indent, index)
      count = 0
      (from_idx...@lines.size).each do |i|
        indent = line_indent(i)
        break if indent <= parent_indent && i > from_idx

        match = @lines[i].match(/^(\s*)- /)
        next unless match
        next unless match[1].length > parent_indent

        return i if count == index

        count += 1
      end
      nil
    end

    def block_range(anchor_idx)
      anchor_indent = line_indent(anchor_idx)
      end_idx = anchor_idx

      (anchor_idx + 1...@lines.size).each do |i|
        line = @lines[i]
        break if line.strip.empty?

        indent = line_indent(i)
        break if indent <= anchor_indent

        end_idx = i
      end

      [anchor_idx + 1, end_idx + 1]
    end

    def line_indent(index)
      match = @lines[index].match(/^(\s*)/)
      match ? match[1].length : 0
    end
  end
end
