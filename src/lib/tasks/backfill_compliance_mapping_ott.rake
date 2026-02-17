namespace :compliance do
  desc "Backfill ontology_term_type_id on compliance_mappings from field_group_id. " \
       "Usage: rake compliance:backfill_mapping_ott [DRY_RUN=true]"
  task backfill_mapping_ott: :environment do
    dry_run = ENV['DRY_RUN'] == 'true'

    ott_lookup = OntologyTermType.where.not(field_group_id: [nil, ''])
                                 .pluck(:field_group_id, :id)
                                 .to_h

    if ott_lookup.empty?
      puts "No OntologyTermType records with field_group_id found. Nothing to do."
      next
    end

    puts "OntologyTermType mapping (field_group_id -> id):"
    ott_lookup.each { |fg, ott_id| puts "  #{fg} -> #{ott_id}" }

    mappings = ComplianceMapping.where(ontology_term_type_id: nil)
    total = mappings.count
    puts "#{total} ComplianceMapping record(s) to backfill."

    if dry_run
      puts "[DRY RUN] No changes applied."
      next
    end

    updated = 0
    skipped = 0

    mappings.find_each do |cm|
      ott_id = ott_lookup[cm.field_group_id]
      if ott_id
        cm.update_column(:ontology_term_type_id, ott_id)
        updated += 1
      else
        puts "  SKIP ComplianceMapping##{cm.id}: no OntologyTermType for field_group_id='#{cm.field_group_id}'"
        skipped += 1
      end
    end

    puts "Done. Updated: #{updated}, Skipped: #{skipped}."
  end
end
