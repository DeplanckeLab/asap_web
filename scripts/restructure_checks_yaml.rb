# frozen_string_literal: true

require 'yaml'
require 'set'

rules_path = File.expand_path('../src/config/scfair/7.1.0/rules.yaml', __dir__)
data = YAML.safe_load_file(rules_path, aliases: true)
flat = data['checks'] || {}

categories = flat.select { |_, v| v.is_a?(Hash) && v['kind'] == 'category' }
children = flat.select { |_, v| v.is_a?(Hash) && v['kind'] == 'check' }
category_ids = categories.keys.to_set

catalog = {
  'common' => [],
  'loom_only' => [],
  'h5ad_only' => []
}

# Rebuild catalog from formats on categories (preserve sidebar order from current file)
flat.each do |id, cfg|
  next unless cfg.is_a?(Hash) && cfg['kind'] == 'category'
  next unless cfg['formats'].is_a?(Array)

  fmts = cfg['formats'].map(&:to_s)
  if fmts.include?('h5ad') && fmts.include?('loom')
    catalog['common'] << id
  elsif fmts == ['loom']
    catalog['loom_only'] << id
  elsif fmts == ['h5ad']
    catalog['h5ad_only'] << id
  else
    catalog['common'] << id
  end
end

def nested_check_key(check_id, category_id, cfg)
  field = cfg['field'].to_s
  return field unless field.empty?

  remainder = check_id.to_s.delete_prefix("#{category_id}.")
  remainder.empty? ? check_id.to_s : remainder
end

hierarchical = { 'catalog' => catalog }

categories.each do |cat_id, cat_cfg|
  entry = cat_cfg.reject { |k, _| k == 'kind' }
  if entry['checks_performed']
    entry['rollup'] = entry.delete('checks_performed')
  end

  child_entries = children.select { |_, v| v['category'] == cat_id }
  if child_entries.any?
    entry['checks'] = {}
    child_entries.each do |check_id, check_cfg|
      key = nested_check_key(check_id, cat_id, check_cfg)
      if entry['checks'].key?(key)
        suffix = check_id.to_s.delete_prefix("#{cat_id}.")
        key = suffix if suffix.present? && suffix != key
      end
      key = 'ensembl_assembly.optional' if key == 'ensembl_assembly' && cat_id == 'uns.required_presence' && category_ids.include?('uns.ensembl_assembly')

      child = check_cfg.reject { |k, _| %w[kind category].include?(k) }
      child['checks_performed'] ||= child.delete('checks') if child['checks'].is_a?(Array)
      entry['checks'][key] = child
    end
  end

  hierarchical[cat_id] = entry
end

header = File.read(rules_path).split(/^# Unified compliance check registry:/).first.rstrip
check_details_part = File.read(rules_path).split(/^check_details:\s*$/).last
check_details_yaml = "check_details:#{check_details_part}"

out = header + "\n\n" +
      "# Unified compliance check registry: categories as shown in the compliance report UI.\n" +
      "# Each category has metadata (label, formats, summary, rollup, messages) and optional nested checks.\n" +
      "# checks.catalog lists sidebar category ids per file format.\n" +
      YAML.dump({ 'checks' => hierarchical }).sub(/^---\n/, '') +
      "\n# UI helpers for check detail popups (field summaries, semantic subcheck labels, spatial rollup).\n" +
      check_details_yaml

File.write(rules_path, out)
puts "Wrote #{hierarchical.size - 1} categories + catalog"
puts "  common: #{catalog['common'].size}, loom_only: #{catalog['loom_only'].size}, h5ad_only: #{catalog['h5ad_only'].size}"
