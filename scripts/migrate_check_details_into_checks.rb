# frozen_string_literal: true

require 'yaml'

rules_path = File.expand_path('../src/config/scfair/7.1.0/rules.yaml', __dir__)
data = YAML.safe_load_file(rules_path, aliases: true)
details = data.delete('check_details') || {}
checks = data['checks'] || {}

# defaults -> checks._defaults
checks['_defaults'] = details['defaults'] if details['defaults']

# spatial rollup -> extension.spatial.rollup
if details['spatial_rollup_checks']
  checks['extension.spatial'] ||= {}
  checks['extension.spatial']['rollup'] = details['spatial_rollup_checks']
end

# semantic labels -> ontology.semantics
if details['semantic']
  checks['ontology.semantics'] ||= {}
  checks['ontology.semantics']['semantic_labels'] = details['semantic']
end

# field summaries -> nested check summary
Array(%w[uns var]).each do |layer|
  summaries = details.dig('field_summaries', layer) || {}
  summaries.each do |field_name, summary|
    category_id = case layer
                  when 'uns' then 'uns.required_presence'
                  when 'var' then 'var.required'
                  end
    next if category_id.nil? || category_id.empty?

    checks[category_id] ||= {}
    checks[category_id]['checks'] ||= {}
    checks[category_id]['checks'][field_name] ||= {}
    checks[category_id]['checks'][field_name]['summary'] ||= summary
    checks[category_id]['checks'][field_name]['layer'] ||= layer
    checks[category_id]['checks'][field_name]['field'] ||= field_name
  end
end

data['checks'] = checks

header_lines = File.read(rules_path).lines.take_while { |l| !l.start_with?('# Unified compliance check registry:') }
header = header_lines.join.rstrip
header = header.gsub(
  "#   check_details           - UI helpers (field summaries, semantic labels, spatial rollup)\n",
  ''
)

out = header + "\n\n" +
      "# Unified compliance check registry: categories as shown in the compliance report UI.\n" +
      "# Each category has metadata (label, formats, summary, rollup, messages) and optional nested checks.\n" +
      "# checks.catalog lists sidebar category ids per file format.\n" +
      "# checks._defaults provides fallback popup summary templates.\n" +
      YAML.dump({ 'checks' => checks }).sub(/^---\n/, '')

File.write(rules_path, out)
puts 'Removed check_details; migrated into checks.'
