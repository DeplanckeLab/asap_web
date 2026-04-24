# frozen_string_literal: true

require 'shellwords'

class StdMethod < ApplicationRecord
  belongs_to :step
  belongs_to :docker_image, optional: true
  has_many :reqs, dependent: :nullify
  has_many :runs, dependent: :nullify

  # Human-readable entrypoint for admin lists (script name, jar, or rails task), not the full interpreter line.
  def command_program
    raw = raw_command_program_string
    return nil if raw.blank?

    self.class.command_program_display_name(raw)
  end

  def raw_command_program_string
    h = Basic.safe_parse_json(command_json, {})
    return nil unless h.is_a?(Hash)

    p = h['program']
    p.present? ? p.to_s : nil
  end

  def self.command_program_display_name(raw)
    raw = raw.to_s.strip
    return nil if raw.empty?

    tokens = shell_tokens(raw)
    return raw if tokens.length <= 1

    name = display_name_from_program_tokens(tokens)
    name.presence || raw
  end

  def self.shell_tokens(raw)
    Shellwords.split(raw)
  rescue ArgumentError
    raw.split(/\s+/)
  end

  def self.display_name_from_program_tokens(parts)
    if parts[0] == 'bundle' && parts[1] == 'exec' && parts[2]
      rest = parts[2..]
      return nil if rest.empty?

      if rest[0] == 'rails' && rest[1]
        return rest[1..].join(' ')
      end

      return rest.join(' ')
    end

    head = File.basename(parts[0])

    case head
    when 'java', 'openjdk'
      i = parts.index('-jar')
      return File.basename(parts[i + 1]) if i && parts[i + 1]
    end

    if head.start_with?('python') || %w[pypy pypy3].include?(head)
      arg = first_non_flag_token(parts, 1)
      return File.basename(arg) if arg
    end

    case head
    when 'Rscript'
      arg = first_non_flag_token(parts, 1)
      return File.basename(arg) if arg
    when 'ruby', 'perl', 'node', 'nodejs'
      arg = first_non_flag_token(parts, 1)
      return File.basename(arg) if arg
    when 'rails'
      return parts[1..].join(' ') if parts.length > 1
    end

    nil
  end

  def self.first_non_flag_token(parts, start_idx)
    parts[start_idx..]&.each do |t|
      next if t.start_with?('-')

      return t
    end
    nil
  end
end
