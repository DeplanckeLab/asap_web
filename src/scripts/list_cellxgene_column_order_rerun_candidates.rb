# frozen_string_literal: true

# List CellxGENE catalog candidate ids whose latest admin standalone check
# failed with the obs column-order "not stored in the file" false positive
# (underscore-prefixed columns such as _scvi_batch, _scvi_labels, _indices).
#
# Run on production inside the website container, e.g.:
#   docker-compose exec website bundle exec rails runner scripts/list_cellxgene_column_order_rerun_candidates.rb
#
# Optional env:
#   OUT=tmp/column_order_rerun_candidates.tsv
#   MATCH=underscore   (default: only when all missing cols start with _)
#   MATCH=scvi         (column-order error mentioning _scvi_* or _indices)
#   MATCH=any          (any column-order not-stored error)

require 'fileutils'

MATCH_MODE = ENV.fetch('MATCH', 'underscore').downcase
OUT_PATH = ENV.fetch('OUT', Rails.root.join('tmp/column_order_rerun_candidates.tsv').to_s)

def column_order_missing_columns(message)
  msg = message.to_s
  return [] unless msg.include?('column-order attribute lists') && msg.include?('not stored in the file')

  if (m = msg.match(/lists (\d+) columns not stored in the file: (.+?)\. The obs table/m))
    m[2].split(',').map { |s| s.strip.sub(/\s*\(\+\d+ more\)\z/, '') }
  elsif (m = msg.match(/lists (.+?), which is not stored in the file/m))
    [m[1].strip]
  else
    []
  end
end

def column_order_error_messages(result_json)
  return [] unless result_json.is_a?(Hash)

  messages = Array(result_json['errors']).filter_map { |e| e['message'].to_s.presence }
  Array(result_json['check_groups']).each do |group|
    Array(group['items']).each do |item|
      msg = item['message'].to_s.presence
      msg ||= item.dig('detail', 'message').to_s.presence
      messages << msg if msg.present?
    end
  end
  messages.uniq.select { |m| m.include?('column-order attribute lists') && m.include?('not stored in the file') }
end

def matches_mode?(message)
  case MATCH_MODE
  when 'any'
    true
  when 'scvi'
    message.include?('_scvi_batch') || message.include?('_scvi_labels') || message.include?('_indices')
  else
    cols = column_order_missing_columns(message)
    cols.any? && cols.all? { |c| c.start_with?('_') && !c.start_with?('__') }
  end
end

def check_has_target_error?(check)
  column_order_error_messages(check.result_json).any? { |msg| matches_mode?(msg) }
end

def latest_admin_check_by_url
  rows = StandaloneComplianceCheck.admin_runs
                                  .where(status: 'completed')
                                  .where.not(source_url: [nil, ''])
                                  .order(checked_at: :desc)
                                  .pluck(:source_url, :id, :passed, :checked_at, :filename)
  by_url = {}
  rows.each do |url, id, passed, checked_at, filename|
    next if by_url.key?(url)

    by_url[url] = { id: id, passed: passed, checked_at: checked_at, filename: filename }
  end
  by_url
end

def latest_admin_check_by_filename
  rows = StandaloneComplianceCheck.admin_runs
                                  .where(status: 'completed')
                                  .where.not(filename: [nil, ''])
                                  .order(checked_at: :desc)
                                  .pluck(:filename, :id, :passed, :checked_at, :source_url)
  by_name = {}
  rows.each do |filename, id, passed, checked_at, source_url|
    next if by_name.key?(filename)

    by_name[filename] = { id: id, passed: passed, checked_at: checked_at, source_url: source_url }
  end
  by_name
end

candidates = ExternalCatalogCandidate.current
                                     .for_project_type('sc')
                                     .for_source('cellxgene')
                                     .non_test_entry
                                     .where.not(url: [nil, ''])

by_url = latest_admin_check_by_url
by_filename = latest_admin_check_by_filename
checks_by_id = {}

matched = []
unmatched_check = []
no_check = []

candidates.find_each do |candidate|
  meta = by_url[candidate.url.to_s]
  meta ||= by_filename[candidate.filename.to_s] if candidate.filename.present?

  unless meta
    no_check << candidate.id
    next
  end

  check = checks_by_id[meta[:id]] ||= StandaloneComplianceCheck.find_by(id: meta[:id])
  unless check
    unmatched_check << candidate.id
    next
  end

  next if check.passed?

  msgs = column_order_error_messages(check.result_json).select { |m| matches_mode?(m) }
  next if msgs.empty?

  matched << {
    candidate_id: candidate.id,
    external_id: candidate.external_id,
    filename: candidate.filename,
    check_id: check.id,
    checked_at: check.checked_at,
    missing: column_order_missing_columns(msgs.first).join('|'),
    message: msgs.first
  }
end

ids = matched.map { |r| r[:candidate_id] }.sort

puts "MATCH=#{MATCH_MODE}"
puts "cellxgene sc candidates with url: #{candidates.count}"
puts "matched for rerun: #{ids.size}"
puts "no admin completed check: #{no_check.size}"
puts "CANDIDATE_IDS=#{ids.join(',')}"
puts

matched.first(10).each do |r|
  puts [r[:candidate_id], r[:external_id], r[:missing], r[:checked_at]].join("\t")
end

FileUtils.mkdir_p(File.dirname(OUT_PATH))
lines = ["candidate_id\texternal_id\tfilename\tcheck_id\tmissing_columns\tchecked_at\n"]
matched.each do |r|
  lines << [r[:candidate_id], r[:external_id], r[:filename], r[:check_id], r[:missing], r[:checked_at]].join("\t") + "\n"
end
File.write(OUT_PATH, lines.join)
puts "\nWrote #{OUT_PATH}"

# Extra diagnostics when count looks low
if ids.size < 400
  sql_count = StandaloneComplianceCheck.admin_runs
                                       .where(status: 'completed')
                                       .where("result_json::text ILIKE ?", '%column-order attribute lists%not stored in the file%')
                                       .where("result_json::text ILIKE ?", '%_scvi_%')
                                       .count
  puts "\nDiagnostic: admin completed checks with column-order + _scvi in JSON: #{sql_count}"
  puts "(If this is ~535 but matched is lower, URL/filename linkage to candidates is the gap.)"
end
