# frozen_string_literal: true

require "set"

module AsapData
  # Mark gene_set_items.obsolete from the organism's latest Ensembl dump only.
  # Does not change content. Prefer `rails update_xrefs` for a full refresh
  # (content + latest_ensembl_release + obsolete); this task is for presence /
  # obsolete marking without rewriting annotations.
  #
  # Present identifier  -> obsolete=false, latest_ensembl_release=organism.latest
  # Absent identifier   -> obsolete=true
  #
  # ENV: ASAP2_REMOTE_DB, ENSEMBL_DATA_DIR, ORGANISM, XREF_BATCH_SIZE
  module GeneSetItemObsoleteBackfill
    module_function

    ENSEMBL_GENE_SET_LABELS = [
      "GO Biological Processes",
      "GO Cellular Components",
      "GO Molecular Functions",
      "KEGG pathways",
      "DrugBank",
      "Reactome"
    ].freeze

    H_DB_TO_LOAD = {
      "1000" => { name: "GO" },
      "50801" => { name: "KEGG pathways" },
      "20062" => { name: "DrugBank" },
      "20088" => { name: "Reactome" }
    }.freeze

    LIST_DB_XREFS_DIRECT = %w[50801 20062 20088].freeze
    LIST_DB_XREFS = (["1000"] + LIST_DB_XREFS_DIRECT).freeze
    REQUIRED_TABLES = %w[gene xref object_xref transcript].freeze
    OPTIONAL_TABLES = %w[translation].freeze

    def default_remote_db
      ENV.fetch("ASAP2_REMOTE_DB", "asap_data_v8")
    end

    def ensembl_data_dir
      if ENV["ENSEMBL_DATA_DIR"].present?
        Pathname.new(ENV["ENSEMBL_DATA_DIR"])
      elsif defined?(APP_CONFIG) && APP_CONFIG.respond_to?(:[]) && APP_CONFIG[:data_dir]
        Pathname.new(APP_CONFIG[:data_dir]) + "ensembl"
      else
        Pathname.new("/mnt/asap_data/ensembl")
      end
    end

    def resolve_go_json_path
      candidates = [
        ENV["GO_JSON_PATH"],
        ENV["PROD_DATA_DIR"].present? ? File.join(ENV["PROD_DATA_DIR"], "go", "go.json") : nil,
        "/data/asap/go/go.json",
        "/mnt/asap_data/go/go.json"
      ].compact
      path = candidates.find { |p| File.exist?(p) }
      raise "go.json not found (tried: #{candidates.join(', ')})" unless path

      path
    end

    def batch_size
      (ENV["XREF_BATCH_SIZE"].presence || 5000).to_i
    end

    def organism_filter
      ENV["ORGANISM"].to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def backfill!(remote_db: default_remote_db)
      stats = {
        organisms_total: 0,
        organisms_processed: 0,
        organisms_skipped: 0,
        items_present: 0,
        items_obsolete: 0
      }

      h_go = JSON.parse(File.read(resolve_go_json_path))
      puts "ensembl data dir: #{ensembl_data_dir}"
      puts "strategy: latest release only; set obsolete=true when identifier absent"

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
          h_subdomains = EnsemblSubdomain.all.index_by(&:id)
          organisms = Organism.all.to_a
          filter = organism_filter
          organisms.select! { |o| filter.include?(o.ensembl_db_name) } if filter.any?
          stats[:organisms_total] = organisms.size

          organisms.each do |organism|
            result = process_organism!(organism, h_subdomains, h_go)
            if result[:skipped]
              stats[:organisms_skipped] += 1
              puts "Skip #{organism.ensembl_db_name}: #{result[:reason]}"
            else
              stats[:organisms_processed] += 1
              stats[:items_present] += result[:items_present]
              stats[:items_obsolete] += result[:items_obsolete]
              puts "Organism #{organism.ensembl_db_name}: " \
                   "present=#{result[:items_present]} obsolete=#{result[:items_obsolete]}"
            end
          end
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

      stats
    end

    def process_organism!(organism, h_subdomains, h_go)
      subdomain = h_subdomains[organism.ensembl_subdomain_id]
      return { skipped: true, reason: "missing subdomain" } unless subdomain

      release_num = organism.latest_ensembl_release.to_i
      return { skipped: true, reason: "latest_ensembl_release blank" } if release_num <= 0

      gene_sets = GeneSet.where(organism_id: organism.id, label: ENSEMBL_GENE_SET_LABELS).to_a
      return { skipped: true, reason: "no ensembl gene sets" } if gene_sets.empty?

      organism_dir = ensure_organism_dir!(subdomain.name, release_num, organism.ensembl_db_name)
      return { skipped: true, reason: "tables not local at release #{release_num}" } unless organism_dir

      bundle = parse_xref_bundle(organism_dir, organism.tag)
      h_gsi = build_gsi(bundle)
      apply_go_lineages!(h_gsi, h_go)
      present_by_gs = present_identifiers_by_gene_set(h_gsi, h_go, gene_sets)

      items_present = 0
      items_obsolete = 0
      now = Time.now

      gene_sets.each do |gene_set|
        present = present_by_gs[gene_set.id] || Set.new
        if present.any?
          present.each_slice(batch_size) do |slice|
            n = GeneSetItem.where(gene_set_id: gene_set.id, identifier: slice)
              .update_all(obsolete: false, latest_ensembl_release: release_num, updated_at: now)
            items_present += n
          end
        end

        missing_scope = GeneSetItem.where(gene_set_id: gene_set.id, obsolete: false)
        missing_scope = present.empty? ? missing_scope : missing_scope.where.not(identifier: present.to_a)
        n_obs = missing_scope.update_all(obsolete: true, updated_at: now)
        items_obsolete += n_obs

        if gene_set.latest_ensembl_release.to_i != release_num
          gene_set.update_columns(latest_ensembl_release: release_num, updated_at: now)
        end
      end

      {
        skipped: false,
        items_present: items_present,
        items_obsolete: items_obsolete
      }
    end

    def present_identifiers_by_gene_set(h_gsi, h_go, gene_sets)
      gene_sets_by_label = gene_sets.index_by(&:label)
      out = Hash.new { |h, k| h[k] = Set.new }

      h_gsi["1000"].each_key do |go_id|
        db_name = h_go.dig(go_id, "db_name")
        next if db_name.blank?

        gene_set = gene_sets_by_label[db_name]
        next unless gene_set

        out[gene_set.id] << go_id
      end

      LIST_DB_XREFS_DIRECT.each do |type|
        db_name = H_DB_TO_LOAD[type][:name]
        gene_set = gene_sets_by_label[db_name]
        next unless gene_set

        h_gsi[type].each_key { |identifier| out[gene_set.id] << identifier }
      end

      out
    end

    def ensure_organism_dir!(subdomain, release_num, db_name)
      release_dir = ensembl_data_dir + subdomain.to_s + release_num.to_s
      organism_dir = release_dir + db_name
      archive = release_dir + "#{db_name}.tgz"

      return organism_dir if tables_ready?(organism_dir)

      if File.exist?(archive) && File.size(archive) >= 350
        missing = missing_tables(organism_dir, REQUIRED_TABLES + OPTIONAL_TABLES)
        if missing.any?
          puts "  Unzipping #{archive} (missing: #{missing.join(', ')})..."
          system("cd #{release_dir} && tar -zxf #{db_name}.tgz")
        end
      end

      return organism_dir if tables_ready?(organism_dir)

      nil
    end

    def tables_ready?(organism_dir)
      REQUIRED_TABLES.all? { |t| File.exist?(File.join(organism_dir.to_s, "#{t}.txt")) }
    end

    def missing_tables(organism_dir, table_names)
      table_names.reject { |t| File.exist?(File.join(organism_dir.to_s, "#{t}.txt")) }
    end

    def foreach_tsv(path)
      File.foreach(path, mode: "r:ASCII-8BIT") do |line|
        yield line.chomp.split("\t")
      end
    end

    def detect_gene_stable_id_index(sample_fields)
      sample_fields.each_with_index do |field, idx|
        next if field.blank? || field == '\N'
        return idx if field.match?(/\A[A-Z0-9]+G\d+\z/) || field.match?(/\AFBgn\d+\z/i)
      end
      12
    end

    def parse_xref_bundle(organism_dir, organism_tag)
      h_transcript = {}
      transcript_path = File.join(organism_dir.to_s, "transcript.txt")
      if File.exist?(transcript_path)
        foreach_tsv(transcript_path) { |t| h_transcript[t[0]] = t[1] }
      end

      h_translation = {}
      translation_path = File.join(organism_dir.to_s, "translation.txt")
      if File.exist?(translation_path)
        foreach_tsv(translation_path) { |t| h_translation[t[0]] = t[1] }
      end

      h_xref = {}
      foreach_tsv(File.join(organism_dir.to_s, "xref.txt")) do |t|
        next unless H_DB_TO_LOAD.key?(t[1])

        xref_acc = if t[1] == "50801"
          "#{organism_tag || ''}#{t[2].to_s.split('+').first}"
        else
          t[2]
        end
        h_xref[t[0]] = { acc: xref_acc, type: t[1] }
      end

      h_object_xref = {}
      H_DB_TO_LOAD.each_key { |k| h_object_xref[k] = {} }
      foreach_tsv(File.join(organism_dir.to_s, "object_xref.txt")) do |t|
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
      foreach_tsv(File.join(organism_dir.to_s, "gene.txt")) do |t|
        stable_idx ||= detect_gene_stable_id_index(t)
        stable_id = t[stable_idx]
        next if stable_id.blank? || stable_id == '\N'

        h_gene_internal[stable_id] = t[0]
      end

      { gene_internal: h_gene_internal, object_xref: h_object_xref, xref: h_xref }
    end

    def build_gsi(bundle)
      h_gsi = {}
      LIST_DB_XREFS.each { |type| h_gsi[type] = {} }

      bundle[:gene_internal].each do |_stable_id, internal_id|
        LIST_DB_XREFS.each do |type|
          ox = bundle[:object_xref][type][internal_id]
          next unless ox

          ox.each do |xref_id|
            acc = bundle[:xref][xref_id] && bundle[:xref][xref_id][:acc]
            next unless acc

            h_gsi[type][acc] ||= Set.new
            h_gsi[type][acc] << true
          end
        end
      end
      h_gsi
    end

    def apply_go_lineages!(h_gsi, h_go)
      sets = h_gsi["1000"]
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
  end
end
