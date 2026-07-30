# frozen_string_literal: true

require "digest"
require "set"

# Historical / versioned Ensembl xref loader for gene_set_items.
#
# Walks Ensembl releases from oldest to newest and maintains temporal windows:
#   - first_ensembl_release / latest_ensembl_release on each gene_set_item row
#   - same identifier + same content  -> extend latest_ensembl_release
#   - same identifier + changed content -> leave previous row as-is; insert a new row
#   - identifier absent in a release -> do not extend latest (row becomes historical)
#
# Obsolete items are kept (with a closed latest_ensembl_release), not deleted.
#
# Usage examples:
#   RAILS_ENV=development ASAP2_REMOTE_DB=asap_data_v8 \
#     ENSEMBL_DATA_DIR=/mnt/asap_data/ensembl PROD_DATA_DIR=/data/asap \
#     bundle exec rails update_xrefs_versioned
#
#   ORGANISM=homo_sapiens RELEASE_FROM=100 RELEASE_TO=116 RESET_ITEMS=1 \
#     bundle exec rails update_xrefs_versioned
#
# ENV:
#   ASAP2_REMOTE_DB   remote asap_data_* DB (default asap_data_v8)
#   ASAP_DATA_ID      asap_data_id stamped on rows
#   ENSEMBL_DATA_DIR  local Ensembl mirror
#   RELEASE_FROM      min release to process (per subdomain; default = min local dir)
#   RELEASE_TO        max release (vertebrates default 116, genomes default 63)
#   ORGANISM          optional ensembl_db_name filter (comma-separated)
#   RESET_ITEMS       if 1/true, delete Ensembl-sourced gene_set_items before rebuild
#                     and reset gene_set_items_id_seq (to 1 if table empty, else max(id)+1)
#   DOWNLOAD_MISSING  if 1/true, wget missing mysql tables from Ensembl FTP
#   XREF_BATCH_SIZE   batch size for inserts/updates (default 5000)
#   UPDATE_NCBI       if 1/true, also update genes.ncbi_gene_id from latest release only
#
# Existing rows are never content-updated: same identifier+content only bumps
# latest_ensembl_release; content/name change always inserts a new row.

desc "Load Ensembl xrefs into gene_set_items with first/latest_ensembl_release (oldest to newest)"
task update_xrefs_versioned: :environment do
  $stdout.sync = true
  puts "Executing update_xrefs_versioned..."

  Rails.logger = Logger.new("/dev/null")
  ActiveRecord::Base.logger = Logger.new("/dev/null")

  remote_db = ENV.fetch("ASAP2_REMOTE_DB", "asap_data_v8")
  asap_data_id = (ENV["ASAP_DATA_ID"].presence || remote_db[/\d+/] || "8").to_i
  batch_size = (ENV["XREF_BATCH_SIZE"].presence || 5000).to_i
  download_missing = ENV["DOWNLOAD_MISSING"].to_s.match?(/\A(1|true|yes)\z/i)
  reset_items = ENV["RESET_ITEMS"].to_s.match?(/\A(1|true|yes)\z/i)
  update_ncbi = ENV["UPDATE_NCBI"].to_s.match?(/\A(1|true|yes)\z/i)
  organism_filter = ENV["ORGANISM"].to_s.split(",").map(&:strip).reject(&:empty?)

  ensembl_gene_set_labels = [
    "GO Biological Processes",
    "GO Cellular Components",
    "GO Molecular Functions",
    "KEGG pathways",
    "DrugBank",
    "Reactome"
  ].freeze

  h_db_to_load = {
    "1300" => { name: "NCBI Gene ID" },
    "1000" => { name: "GO" },
    "50801" => { name: "KEGG pathways" },
    "20062" => { name: "DrugBank" },
    "20088" => { name: "Reactome" }
  }.freeze

  list_db_xrefs_direct = %w[50801 20062 20088]
  list_db_xrefs = ["1000"] + list_db_xrefs_direct
  ensembl_tables = %w[transcript translation gene xref object_xref]

  default_release_to = {
    "vertebrates" => 116,
    "bacteria" => 63,
    "fungi" => 63,
    "metazoa" => 63,
    "plants" => 63,
    "protists" => 63
  }.freeze

  def asap_data_dir
    if defined?(APP_CONFIG) && APP_CONFIG.respond_to?(:[])
      APP_CONFIG[:data_dir]
    elsif ENV["DATA_DIR"].present?
      ENV["DATA_DIR"]
    else
      "/data/asap2_test"
    end
  end

  def ensembl_data_dir
    if ENV["ENSEMBL_DATA_DIR"].present?
      Pathname.new(ENV["ENSEMBL_DATA_DIR"])
    else
      Pathname.new(asap_data_dir) + "ensembl"
    end
  end

  def resolve_go_json_path
    candidates = [
      ENV["GO_JSON_PATH"],
      File.join(asap_data_dir.to_s, "go", "go.json"),
      ENV["PROD_DATA_DIR"].present? ? File.join(ENV["PROD_DATA_DIR"], "go", "go.json") : nil,
      "/data/asap/go/go.json",
      "/mnt/asap_data/go/go.json"
    ].compact
    path = candidates.find { |p| File.exist?(p) }
    raise "go.json not found (tried: #{candidates.join(', ')})" unless path
    path
  end

  def local_releases_for(subdomain)
    dir = ensembl_data_dir + subdomain.to_s
    return [] unless Dir.exist?(dir)

    Dir.children(dir).select { |name| name.match?(/\A\d+\z/) }.map(&:to_i).sort
  end

  def ftp_mysql_base(subdomain, release_num)
    if subdomain.to_s == "vertebrates"
      "ftp://ftp.ensembl.org/pub/release-#{release_num}/mysql/"
    else
      "ftp://ftp.ensemblgenomes.org/pub/release-#{release_num}/#{subdomain}/mysql/"
    end
  end

  def list_core_folders(subdomain, release_num)
    url = ftp_mysql_base(subdomain, release_num)
    listing = `wget -qO - #{url}`
    folders = {}
    listing.to_s.split("\n").each do |line|
      next unless (m = line.match(/>(\w+)\/</))
      next unless (m2 = m[1].match(/\A(.+?)_core_/))

      folders[m2[1]] = m[1]
    end
    folders
  end

  def detect_gene_stable_id_index(sample_fields, known_ensembl_ids)
    sample_fields.each_with_index do |field, idx|
      next if field.blank? || field == '\N'
      return idx if known_ensembl_ids.include?(field)
    end
    sample_fields.each_with_index do |field, idx|
      next if field.blank? || field == '\N'
      return idx if field.match?(/\A[A-Z0-9]+G\d+\z/) || field.match?(/\AFBgn\d+\z/i)
    end
    12
  end

  # transcript is required: Ensembl GO (and most other) object_xrefs hang off Transcript,
  # not Gene. Without transcript.txt, older releases resolve zero annotations and every
  # gene_set_item incorrectly gets first_ensembl_release = first release that has transcripts.
  def required_ensembl_tables
    %w[gene xref object_xref transcript]
  end

  def optional_ensembl_tables
    %w[translation]
  end

  def organism_tables_ready?(organism_dir)
    required_ensembl_tables.all? { |t| File.exist?(File.join(organism_dir.to_s, "#{t}.txt")) }
  end

  def missing_ensembl_tables(organism_dir, table_names)
    table_names.reject { |t| File.exist?(File.join(organism_dir.to_s, "#{t}.txt")) }
  end

  def ensure_organism_tables!(release_dir, db_name, folder_name, subdomain, release_num, ensembl_tables, download_missing)
    archive = release_dir + "#{db_name}.tgz"
    organism_dir = release_dir + db_name
    FileUtils.mkdir_p(organism_dir)

    return organism_dir if organism_tables_ready?(organism_dir)

    # Partial extracts are common (gene/xref/object_xref only). Always try the local tgz
    # for missing required tables before giving up or downloading.
    if File.exist?(archive) && File.size(archive) >= 350
      missing = missing_ensembl_tables(organism_dir, required_ensembl_tables + optional_ensembl_tables)
      if missing.any?
        puts "  Unzipping #{archive} (missing: #{missing.join(', ')})..."
        system("cd #{release_dir} && tar -zxf #{db_name}.tgz")
      end
      return organism_dir if organism_tables_ready?(organism_dir)
    end

    unless download_missing && folder_name
      puts "  Skip #{db_name} @ #{release_num}: tables not local (need #{missing_ensembl_tables(organism_dir, required_ensembl_tables).join(', ')}; set DOWNLOAD_MISSING=1 to fetch)"
      return nil
    end

    mysql_base = ftp_mysql_base(subdomain, release_num)
    ensembl_tables.each do |table_name|
      dest_gz = organism_dir + "#{table_name}.txt.gz"
      dest = organism_dir + "#{table_name}.txt"
      next if File.exist?(dest)

      url = "#{mysql_base}#{folder_name}/#{table_name}.txt.gz"
      puts "  wget #{url}"
      system("wget -qO #{dest_gz} '#{url}'")
      system("gunzip -f #{dest_gz}") if File.exist?(dest_gz)
    end

    return organism_dir if organism_tables_ready?(organism_dir)

    puts "  Skip #{db_name} @ #{release_num}: incomplete Ensembl mysql dump"
    nil
  end

  def parse_xref_bundle(organism_dir, h_db_to_load, organism_tag, known_ensembl_ids)
    # Ensembl mysql dumps are latin1/binary-ish; never assume UTF-8.
    read_tsv = lambda do |path, &block|
      File.foreach(path, mode: "r:ASCII-8BIT") do |line|
        block.call(line.chomp.split("\t"))
      end
    end

    h_transcript = {}
    transcript_path = File.join(organism_dir.to_s, "transcript.txt")
    if File.exist?(transcript_path)
      read_tsv.call(transcript_path) do |t|
        h_transcript[t[0]] = t[1]
      end
    end

    h_translation = {}
    translation_path = File.join(organism_dir.to_s, "translation.txt")
    if File.exist?(translation_path)
      read_tsv.call(translation_path) do |t|
        h_translation[t[0]] = t[1]
      end
    end

    h_xref = {}
    h_xref_names = Hash.new { |h, k| h[k] = {} }
    read_tsv.call(File.join(organism_dir.to_s, "xref.txt")) do |t|
      next unless h_db_to_load.key?(t[1])

      xref_acc = if t[1] == "50801"
        "#{organism_tag || ''}#{t[2].to_s.split('+').first}"
      else
        t[2]
      end
      h_xref[t[0]] = { acc: xref_acc, type: t[1], name: t[5] }
      h_xref_names[t[1]][xref_acc] = t[5]
    end

    h_object_xref = {}
    h_db_to_load.each_key { |k| h_object_xref[k] = {} }
    read_tsv.call(File.join(organism_dir.to_s, "object_xref.txt")) do |t|
      xref = h_xref[t[3]]
      next unless xref

      type = xref[:type]
      gene_ref = t[1]
      if t[2] == "Transcript"
        gene_ref = h_transcript[t[1]]
      elsif t[2] == "Translation"
        gene_ref = h_transcript[h_translation[t[1]]]
      end
      next if gene_ref.blank?

      h_object_xref[type][gene_ref] ||= []
      h_object_xref[type][gene_ref] << t[3] unless h_object_xref[type][gene_ref].include?(t[3])
    end

    h_gene_internal = {}
    stable_idx = nil
    read_tsv.call(File.join(organism_dir.to_s, "gene.txt")) do |t|
      stable_idx ||= detect_gene_stable_id_index(t, known_ensembl_ids)
      stable_id = t[stable_idx]
      next if stable_id.blank? || stable_id == '\N'

      h_gene_internal[stable_id] = t[0]
    end

    { gene_internal: h_gene_internal, object_xref: h_object_xref, xref: h_xref, xref_names: h_xref_names }
  end

  def content_digest(content)
    Digest::SHA256.hexdigest(content.to_s)
  end

  def build_gsi(h_gene_internal, h_object_xref, h_xref, list_db_xrefs)
    h_gsi = {}
    list_db_xrefs.each { |type| h_gsi[type] = {} }

    h_gene_internal.each do |stable_id, internal_id|
      list_db_xrefs.each do |type|
        ox = h_object_xref[type][internal_id]
        next unless ox

        ox.each do |xref_id|
          acc = h_xref[xref_id] && h_xref[xref_id][:acc]
          next unless acc

          h_gsi[type][acc] ||= Set.new
          h_gsi[type][acc] << stable_id
        end
      end
    end
    h_gsi
  end

  # Merge child GO gene sets into lineage ancestors using Set#merge (much faster than Array#|).
  def apply_go_lineages!(h_gsi, h_go)
    go_type = "1000"
    sets = h_gsi[go_type]
    return if sets.empty?

    sets.keys.dup.each do |go_id|
      lineage = h_go.dig(go_id, "lineage")
      next unless lineage

      src = sets[go_id]
      next unless src

      lineage.each do |lineage_go_id|
        (sets[lineage_go_id] ||= Set.new).merge(src)
      end
    end
  end

  def content_for(ensembl_ids, h_genes_at_release)
    gene_ids = []
    ensembl_ids.each do |eid|
      g = h_genes_at_release[eid]
      gene_ids << g[:id] if g
    end
    return "" if gene_ids.empty?

    gene_ids.uniq!
    gene_ids.sort!
    gene_ids.join(",")
  end

  # Insert rows and assign returned ids into the in-memory active map (no full table reload).
  def flush_item_inserts!(rows, batch_size, active)
    return 0 if rows.empty?

    now = Time.now
    rows.each_slice(batch_size) do |slice|
      result = GeneSetItem.insert_all(
        slice.map { |row| row.merge(created_at: now, updated_at: now) },
        record_timestamps: false,
        returning: %w[id gene_set_id identifier]
      )
      result.rows.each do |id, gene_set_id, identifier|
        entry = active.dig(gene_set_id, identifier)
        next unless entry

        entry[:id] = id
        entry.delete(:pending_insert)
      end
    end
    rows.size
  end

  # latest_ensembl_release extensions only (content changes always insert a new row).
  def flush_latest_extensions!(id_release_pairs, asap_data_id, batch_size)
    return 0 if id_release_pairs.empty?

    now = Time.now
    id_release_pairs.group_by { |(_, release_num)| release_num }.each do |release_num, pairs|
      pairs.each_slice(batch_size) do |slice|
        GeneSetItem.where(id: slice.map(&:first)).update_all(
          latest_ensembl_release: release_num,
          asap_data_id: asap_data_id,
          updated_at: now
        )
      end
    end
    id_release_pairs.size
  end

  def ensure_gene_set!(h_gene_sets, h_db_sets, organism, db_name, asap_data_id)
    ref_id = h_db_sets[db_name].id
    gene_set = h_gene_sets[ref_id]
    return gene_set if gene_set

    gene_set = GeneSet.create!(
      organism_id: organism.id,
      label: db_name,
      ref_id: ref_id,
      user_id: 1,
      asap_data_id: asap_data_id
    )
    h_gene_sets[ref_id] = gene_set
    gene_set
  end

  # active[gene_set_id][identifier] stores digest/name/latest — not full content — to cut memory/CPU.
  def apply_versioned_items!(gene_set, identifiers_to_payload, release_num, asap_data_id, active, inserts, latest_extensions)
    active[gene_set.id] ||= {}
    identifiers_to_payload.each do |identifier, payload|
      content = payload[:content]
      next if content.blank?

      name = payload[:name]
      name = nil if name == '\N'
      digest = content_digest(content)
      current = active[gene_set.id][identifier]

      if current.nil?
        inserts << {
          gene_set_id: gene_set.id,
          identifier: identifier,
          name: name,
          content: content,
          asap_data_id: asap_data_id,
          first_ensembl_release: release_num,
          latest_ensembl_release: release_num
        }
        active[gene_set.id][identifier] = {
          id: nil,
          name: name,
          content_digest: digest,
          first_ensembl_release: release_num,
          latest_ensembl_release: release_num,
          pending_insert: true
        }
      elsif current[:content_digest] == digest && current[:name].to_s == name.to_s
        next if current[:latest_ensembl_release].to_i >= release_num

        latest_extensions << [current[:id], release_num] if current[:id]
        current[:latest_ensembl_release] = release_num
      else
        # Content or name changed: leave previous row's latest as-is; open a new version.
        inserts << {
          gene_set_id: gene_set.id,
          identifier: identifier,
          name: name,
          content: content,
          asap_data_id: asap_data_id,
          first_ensembl_release: release_num,
          latest_ensembl_release: release_num
        }
        active[gene_set.id][identifier] = {
          id: nil,
          name: name,
          content_digest: digest,
          first_ensembl_release: release_num,
          latest_ensembl_release: release_num,
          pending_insert: true
        }
      end
    end
  end

  # Initial load only (once per organism). Uses pluck, keeps digests instead of full content.
  def reload_active_items!(gene_set_ids, active)
    active.clear
    return if gene_set_ids.empty?

    GeneSetItem.where(gene_set_id: gene_set_ids).in_batches(of: 10_000) do |relation|
      relation.pluck(:id, :gene_set_id, :identifier, :name, :content, :first_ensembl_release, :latest_ensembl_release).each do |id, gs_id, identifier, name, content, first_r, latest_r|
        active[gs_id] ||= {}
        prev = active[gs_id][identifier]
        next if prev && first_r.to_i < prev[:first_ensembl_release].to_i

        active[gs_id][identifier] = {
          id: id,
          name: name,
          content_digest: content_digest(content),
          first_ensembl_release: first_r,
          latest_ensembl_release: latest_r
        }
      end
    end
  end

  original_organism = Organism
  original_ensembl_subdomain = EnsemblSubdomain

  RemoteGene.with_remote(remote_db) do
    Object.send(:remove_const, :Organism)
    Object.const_set(:Organism, RemoteOrganism)
    Object.const_set(:Gene, RemoteGene)
    Object.send(:remove_const, :EnsemblSubdomain)
    Object.const_set(:EnsemblSubdomain, RemoteEnsemblSubdomain)
    Object.const_set(:DbSet, RemoteDbSet)
    Object.const_set(:GeneSet, RemoteGeneSet)
    Object.const_set(:GeneSetItem, RemoteGeneSetItem)

    begin
      puts "remote db: #{remote_db}"
      puts "ensembl data dir: #{ensembl_data_dir}"
      puts "download missing: #{download_missing}"
      puts "reset items: #{reset_items}"

      go_file = resolve_go_json_path
      puts "GO lineages: #{go_file}"
      h_go = JSON.parse(File.read(go_file))

      list_db_xrefs_direct.each do |db_id|
        label = h_db_to_load[db_id][:name]
        db_set = DbSet.find_or_initialize_by(label: label)
        db_set.tag = h_db_to_load[db_id][:tag]
        db_set.save!
      end

      h_db_sets = DbSet.all.index_by(&:label)
      h_subdomains = EnsemblSubdomain.all.index_by(&:id)

      if reset_items
        gs_ids = GeneSet.where(label: ensembl_gene_set_labels).pluck(:id)
        if organism_filter.any?
          org_ids = Organism.where(ensembl_db_name: organism_filter).pluck(:id)
          gs_ids = GeneSet.where(id: gs_ids, organism_id: org_ids).pluck(:id)
        end
        deleted = GeneSetItem.where(gene_set_id: gs_ids).delete_all
        GeneSet.where(id: gs_ids).update_all(latest_ensembl_release: nil)

        max_id = GeneSetItem.maximum(:id)
        if max_id.nil?
          ActiveRecord::Base.connection.execute(
            "SELECT setval(pg_get_serial_sequence('gene_set_items', 'id'), 1, false)"
          )
          puts "RESET_ITEMS: deleted #{deleted} gene_set_items across #{gs_ids.size} gene_sets; sequence reset to 1"
        else
          ActiveRecord::Base.connection.execute(
            "SELECT setval(pg_get_serial_sequence('gene_set_items', 'id'), #{max_id.to_i}, true)"
          )
          puts "RESET_ITEMS: deleted #{deleted} gene_set_items across #{gs_ids.size} gene_sets; sequence set to #{max_id} (next=#{max_id.to_i + 1})"
        end
      end

      organisms = Organism.all.to_a
      organisms.select! { |o| organism_filter.include?(o.ensembl_db_name) } if organism_filter.any?

      # Cache FTP core folder names per subdomain/release when downloading.
      ftp_folder_cache = Hash.new { |h, k| h[k] = {} }

      organisms.each do |organism|
        subdomain = h_subdomains[organism.ensembl_subdomain_id]
        unless subdomain
          puts "Skip #{organism.ensembl_db_name}: missing subdomain"
          next
        end
        es = subdomain.name
        target_to = (ENV["RELEASE_TO"].presence || default_release_to[es] || organism.latest_ensembl_release).to_i
        local_releases = local_releases_for(es)
        next if local_releases.empty? && !download_missing

        from = (ENV["RELEASE_FROM"].presence || local_releases.min || 1).to_i
        releases = if download_missing
          (from..target_to).to_a
        else
          local_releases.select { |r| r >= from && r <= target_to }
        end
        next if releases.empty?

        puts "=" * 60
        puts "Organism #{organism.ensembl_db_name} (#{es}) releases #{releases.first}..#{releases.last}"

        # Genes known for this organism, with release windows.
        h_genes = {}
        Gene.where(organism_id: organism.id).pluck(:id, :ensembl_id, :ncbi_gene_id, :first_ensembl_release, :latest_ensembl_release).each do |id, eid, ncbi, first_r, latest_r|
          next if eid.blank?

          h_genes[eid] = {
            id: id,
            ensembl_id: eid,
            ncbi_gene_id: ncbi,
            first_ensembl_release: first_r.to_i,
            latest_ensembl_release: latest_r.to_i
          }
        end
        known_ensembl_ids = h_genes.keys.to_set

        h_gene_sets = GeneSet.where(organism_id: organism.id).index_by(&:ref_id)
        active = {}
        reload_active_items!(h_gene_sets.values.map(&:id), active)

        # Resume: if gene_sets already stamped, start after min stamp among Ensembl sets.
        ensembl_gs = h_gene_sets.values.select { |gs| ensembl_gene_set_labels.include?(gs.label) }
        resume_after = ensembl_gs.map { |gs| gs.latest_ensembl_release.to_i }.reject(&:zero?).min
        if resume_after && ENV["RELEASE_FROM"].blank? && !reset_items
          releases = releases.select { |r| r > resume_after }
          puts "  Resume after release #{resume_after} (#{releases.size} releases left)"
        end

        releases.each do |release_num|
          release_dir = ensembl_data_dir + es.to_s + release_num.to_s
          FileUtils.mkdir_p(release_dir)

          folder_name = nil
          if download_missing
            ftp_folder_cache[es][release_num] ||= list_core_folders(es, release_num)
            folder_name = ftp_folder_cache[es][release_num][organism.ensembl_db_name]
          end

          organism_dir = ensure_organism_tables!(
            release_dir, organism.ensembl_db_name, folder_name, es, release_num, ensembl_tables, download_missing
          )
          unless organism_dir
            puts "  #{release_num}: no data"
            next
          end

          puts "  Release #{release_num}..."
          bundle = parse_xref_bundle(organism_dir, h_db_to_load, organism.tag, known_ensembl_ids)
          h_gsi = build_gsi(bundle[:gene_internal], bundle[:object_xref], bundle[:xref], list_db_xrefs)
          apply_go_lineages!(h_gsi, h_go)

          # Genes present at this release (by gene windows). Fallback: any gene in dump mapped in DB.
          h_genes_at_release = {}
          bundle[:gene_internal].each_key do |eid|
            g = h_genes[eid]
            next unless g

            first_r = g[:first_ensembl_release]
            latest_r = g[:latest_ensembl_release]
            if first_r.positive? && latest_r.positive?
              next unless first_r <= release_num && release_num <= latest_r
            end
            h_genes_at_release[eid] = g
          end

          if update_ncbi && release_num == releases.last
            ncbi_type = "1300"
            ncbi_updates = []
            bundle[:gene_internal].each do |stable_id, internal_id|
              g = h_genes[stable_id]
              next unless g

              ox = bundle[:object_xref][ncbi_type][internal_id]
              next unless ox

              acc = bundle[:xref][ox.first] && bundle[:xref][ox.first][:acc]
              next if acc.blank? || g[:ncbi_gene_id].to_s == acc.to_s

              ncbi_updates << { id: g[:id], ncbi_gene_id: acc }
              g[:ncbi_gene_id] = acc
            end
            ncbi_updates.each_slice(batch_size) do |slice|
              Gene.upsert_all(slice, unique_by: :id, update_only: [:ncbi_gene_id])
            end
            puts "    NCBI updates: #{ncbi_updates.size}"
          end

          inserts = []
          latest_extensions = []

          # GO collections
          go_type = "1000"
          go_db_names = h_gsi[go_type].keys.select { |go_id| h_go[go_id] }.map { |go_id| h_go[go_id]["db_name"] }.uniq
          go_db_names.each do |db_name|
            next unless h_db_sets[db_name]

            gene_set = ensure_gene_set!(h_gene_sets, h_db_sets, organism, db_name, asap_data_id)
            payload = {}
            h_gsi[go_type].each do |go_id, ensembl_ids|
              next unless h_go[go_id] && h_go[go_id]["db_name"] == db_name

              content = content_for(ensembl_ids, h_genes_at_release)
              next if content.blank?

              name = bundle[:xref_names][go_type][go_id] || h_go[go_id]["name"]
              payload[go_id] = { content: content, name: name }
            end
            apply_versioned_items!(gene_set, payload, release_num, asap_data_id, active, inserts, latest_extensions)
          end

          # Direct collections
          list_db_xrefs_direct.each do |type|
            db_name = h_db_to_load[type][:name]
            next unless h_db_sets[db_name]
            next if h_gsi[type].empty?

            gene_set = ensure_gene_set!(h_gene_sets, h_db_sets, organism, db_name, asap_data_id)
            payload = {}
            h_gsi[type].each do |identifier, ensembl_ids|
              content = content_for(ensembl_ids, h_genes_at_release)
              next if content.blank?

              payload[identifier] = {
                content: content,
                name: bundle[:xref_names][type][identifier]
              }
            end
            apply_versioned_items!(gene_set, payload, release_num, asap_data_id, active, inserts, latest_extensions)
          end

          n_ins = flush_item_inserts!(inserts, batch_size, active)
          n_upd = flush_latest_extensions!(latest_extensions, asap_data_id, batch_size)
          puts "    items inserted=#{n_ins} updated=#{n_upd}"

          # Stamp gene_sets with the release we successfully processed.
          gs_ids_to_stamp = ensembl_gene_set_labels.filter_map do |label|
            next unless h_db_sets[label]

            gene_set = h_gene_sets[h_db_sets[label].id]
            next unless gene_set
            next unless gene_set.latest_ensembl_release.to_i < release_num

            gene_set.latest_ensembl_release = release_num
            gene_set.asap_data_id = asap_data_id
            gene_set.id
          end
          if gs_ids_to_stamp.any?
            GeneSet.where(id: gs_ids_to_stamp).update_all(
              latest_ensembl_release: release_num,
              asap_data_id: asap_data_id,
              updated_at: Time.now
            )
          end
        end
      end

      puts "Done update_xrefs_versioned."
    ensure
      Object.send(:remove_const, :GeneSetItem) if defined?(GeneSetItem) && GeneSetItem == RemoteGeneSetItem
      Object.send(:remove_const, :GeneSet) if defined?(GeneSet) && GeneSet == RemoteGeneSet
      Object.send(:remove_const, :DbSet) if defined?(DbSet) && DbSet == RemoteDbSet
      Object.send(:remove_const, :Gene) if defined?(Gene) && Gene == RemoteGene
      Object.send(:remove_const, :Organism)
      Object.const_set(:Organism, original_organism)
      Object.send(:remove_const, :EnsemblSubdomain)
      Object.const_set(:EnsemblSubdomain, original_ensembl_subdomain)
    end
  end
end
