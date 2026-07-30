# frozen_string_literal: true

namespace :asap_data do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Mark gene_set_items.obsolete from each organism's latest Ensembl dump only
    (no content rewrite). Present -> obsolete=false + latest_ensembl_release;
    absent -> obsolete=true. Prefer `rails update_xrefs` for a full refresh.
    ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ORGANISM, XREF_BATCH_SIZE
  DESC
  task backfill_gene_set_item_obsolete: :environment do
    $stdout.sync = true
    Rails.logger = Logger.new("/dev/null")
    ActiveRecord::Base.logger = Logger.new("/dev/null")

    start = Time.now
    remote_db = AsapData::GeneSetItemObsoleteBackfill.default_remote_db

    puts "Backfill gene_set_items.obsolete (latest release only)"
    puts "  remote db: #{remote_db}"
    puts

    stats = AsapData::GeneSetItemObsoleteBackfill.backfill!(remote_db: remote_db)

    elapsed = Time.now - start
    puts
    puts "Done in #{elapsed.round(1)}s"
    puts "  organisms total: #{stats[:organisms_total]}"
    puts "  organisms processed: #{stats[:organisms_processed]}"
    puts "  organisms skipped: #{stats[:organisms_skipped]}"
    puts "  items marked present: #{stats[:items_present]}"
    puts "  items marked obsolete: #{stats[:items_obsolete]}"
  end
end
