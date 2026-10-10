# frozen_string_literal: true

# Prefer parse.v8.py ErrorJSON over docker/rpy2 console noise when persisting parsing/output.json.
class PythonParseFailureMessage
  RPY2_CONSOLE_RE = /R callback write-console:/i.freeze

  def self.displayed_error(output_json_path:, parse_stdout:, exitstatus:, preparsing_warnings: [])
    existing = read_displayed_error(output_json_path)
    return normalize(existing) if useful?(existing)

    raw = parse_stdout.to_s.strip
    raw = "Python parser failed with exit status #{exitstatus}" if raw.blank?

    mapped = Hdf5FileCheck.user_message(raw)
    return mapped if mapped.present?

    cleaned = strip_rpy2_console(raw)
    return cleaned if useful?(cleaned)

    warnings = Array(preparsing_warnings).flatten.map { |w| w.to_s.strip }.reject(&:blank?)
    return warnings.join("\n") if warnings.any?

    raw
  end

  def self.useful?(text)
    strip_rpy2_console(Array(text).join("\n")).present?
  end

  def self.read_displayed_error(path)
    return nil unless path && File.exist?(path.to_s)

    h = Basic.safe_parse_json(File.read(path.to_s), {})
    h['displayed_error']
  rescue StandardError
    nil
  end

  def self.strip_rpy2_console(text)
    text.to_s.lines.reject { |line| line.match?(RPY2_CONSOLE_RE) || line.strip.blank? }.join.strip
  end

  def self.normalize(text)
    Array(text).join("\n").strip
  end
end
