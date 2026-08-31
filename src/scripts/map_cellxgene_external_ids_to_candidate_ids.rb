# frozen_string_literal: true

# Map CellxGENE explore external_ids (UUIDs) to ExternalCatalogCandidate primary keys.
#
# Usage:
#   docker-compose exec -T website bundle exec rails runner scripts/map_cellxgene_external_ids_to_candidate_ids.rb < ids.txt
#   EXTERNAL_IDS=uuid1,uuid2,... docker-compose exec -T website bundle exec rails runner scripts/map_cellxgene_external_ids_to_candidate_ids.rb
#
# Output: CANDIDATE_IDS=... and unmatched external_ids on stderr.

ids = ENV['EXTERNAL_IDS'].to_s.split(/[\s,]+/).map(&:strip).reject(&:empty?)
ids = ARGF.readlines.map(&:strip).reject(&:empty?) if ids.empty? && !STDIN.tty?

ids = ids.map(&:downcase).uniq
found = ExternalCatalogCandidate.current
                                .for_project_type('sc')
                                .for_source('cellxgene')
                                .non_test_entry
                                .where(external_id: ids)
                                .pluck(:external_id, :id)
                                .to_h { |ext, cid| [ext.downcase, cid] }

candidate_ids = ids.filter_map { |ext| found[ext] }
missing = ids.reject { |ext| found.key?(ext) }

puts "external_ids=#{ids.size}"
puts "candidate_ids=#{candidate_ids.size}"
puts "CANDIDATE_IDS=#{candidate_ids.sort.join(',')}"

if missing.any?
  warn "unmatched external_ids (#{missing.size}):"
  missing.each { |ext| warn ext }
end
