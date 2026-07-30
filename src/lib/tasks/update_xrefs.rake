desc '####################### Clean'
task update_xrefs: :environment do

  puts 'Executing...'
  require "set"

  dev_null = Logger.new("/dev/null")
  Rails.logger = dev_null
  ActiveRecord::Base.logger = dev_null
  
  now = Time.now
  remote_db = ENV.fetch("ASAP2_REMOTE_DB", "asap_data_v8")
  asap_data_id = (ENV["ASAP_DATA_ID"].presence || remote_db[/\d+/] || "8").to_i

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

  xref_batch_size = (ENV["XREF_BATCH_SIZE"].presence || 5000).to_i

  def flush_ncbi_gene_updates!(rows, batch_size)
    return 0 if rows.empty?

    rows.each_slice(batch_size) do |slice|
      Gene.upsert_all(slice, unique_by: :id, update_only: [:ncbi_gene_id])
    end
    rows.size
  end

  ensembl_gene_set_labels = [
    "GO Biological Processes",
    "GO Cellular Components",
    "GO Molecular Functions",
    "KEGG pathways",
    "DrugBank",
    "Reactome"
  ].freeze

  def flush_gene_set_item_writes!(inserts, updates, batch_size)
    now = Time.now
    inserts.each_slice(batch_size) do |slice|
      GeneSetItem.insert_all(
        slice.map { |row| row.merge(created_at: now, updated_at: now) },
        record_timestamps: false
      )
    end
    updates.each_slice(batch_size) do |slice|
      # Do not put updated_at in update_only: Rails would also timestamp it and
      # Postgres rejects multiple assignments to the same column.
      GeneSetItem.upsert_all(
        slice.map { |row| row.merge(updated_at: now) },
        unique_by: :id,
        update_only: [:name, :content, :asap_data_id, :latest_ensembl_release, :obsolete],
        record_timestamps: false
      )
    end
    [inserts.size, updates.size]
  end

  # Present in latest release: insert or update content when needed; clear obsolete;
  # stamp latest_ensembl_release. Missing identifiers are marked obsolete separately.
  def queue_gene_set_item_write!(inserts, updates, existing_item, attrs)
    if existing_item
      content_changed =
        existing_item.name.to_s != attrs[:name].to_s ||
        existing_item.content.to_s != attrs[:content].to_s ||
        existing_item.asap_data_id.to_i != attrs[:asap_data_id].to_i
      latest_changed =
        existing_item.latest_ensembl_release.to_i != attrs[:latest_ensembl_release].to_i
      obsolete_changed = existing_item.obsolete != false
      if content_changed || latest_changed || obsolete_changed
        updates << {
          id: existing_item.id,
          gene_set_id: attrs[:gene_set_id],
          identifier: attrs[:identifier],
          name: attrs[:name],
          content: attrs[:content],
          asap_data_id: attrs[:asap_data_id],
          latest_ensembl_release: attrs[:latest_ensembl_release],
          obsolete: false
        }
      end
    else
      inserts << attrs.merge(obsolete: false)
    end
  end

  def mark_missing_gene_set_items_obsolete!(gene_set_id, present_identifiers)
    return 0 unless gene_set_id
    # Never mark everything obsolete when the present set is empty (failed/empty parse).
    return 0 if present_identifiers.nil? || present_identifiers.empty?

    GeneSetItem.where(gene_set_id: gene_set_id, obsolete: false)
      .where.not(identifier: present_identifiers.to_a)
      .update_all(obsolete: true, updated_at: Time.now)
  end

  def ensure_gene_set!(h_gene_sets, h_db_sets, o, db_name, asap_data_id)
    ref_id = h_db_sets[db_name].id
    gene_set = h_gene_sets[ref_id]
    attrs = {
      organism_id: o.id,
      label: db_name,
      ref_id: ref_id,
      user_id: 1,
      asap_data_id: asap_data_id
    }
    if gene_set
      gene_set.update!(attrs)
    else
      gene_set = GeneSet.new(attrs)
      gene_set.save!
      h_gene_sets[ref_id] = gene_set
    end
    gene_set
  end

  def stamp_gene_set_release!(gene_set, o, asap_data_id)
    return unless gene_set

    gene_set.update!(
      asap_data_id: asap_data_id,
      latest_ensembl_release: o.latest_ensembl_release
    )
  end

#  asap_data_id = 5
#  kegg_version = '6.3.5.5'

    h_db_to_load = {
      '1300' => {:name => 'NCBI Gene ID'},
      '1000' => {:name => 'GO'},
      '50801' => {:name => 'KEGG pathways'},
      '20062' => {:name => 'DrugBank'},
      '20088' => {:name => 'Reactome'}
    }

#  list_db_xrefs = ['1000', '50801', '20062', '20088']

  list_db_xrefs_direct = ['50801', '20062', '20088'] ## the ones that are integrated straight away
  list_db_xrefs = ["1000"] + list_db_xrefs_direct

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

  ## update db_sets
  list_db_xrefs_direct.each do |db_id|
    label = h_db_to_load[db_id][:name]
    db_set = DbSet.where(:label => label).first
    h_db_set = {
      :label => label, 
      :tag => h_db_to_load[db_id][:tag]
    }
    if !db_set
      db_set = DbSet.new(h_db_set)
      db_set.save
    else
      db_set.update!(h_db_set)
    end
  end
  
  base_url = "ftp://ftp.ensembl.org/pub/release-116/"
  base_url2 = "ftp://ftp.ebi.ac.uk/ensemblgenomes/pub/release-63/"
  tmp_dir = Pathname.new("./tmp/")
  data_dir = Pathname.new(asap_data_dir)
  puts "remote db: #{remote_db}"
  puts "ensembl data dir: #{ensembl_data_dir}"
  puts "vertebrates FTP: #{base_url}"
  puts "genomes FTP: #{base_url2}"

  ## get organisms
  h_organisms = {}
  Organism.all.each do |o|
    h_organisms[o.id] = o
  end

  ## get db_sets
  h_db_sets = {}
  DbSet.all.each do |d|
    h_db_sets[d.label] = d
  end

  ## get GO lineages
  go_file = resolve_go_json_path
  puts "GO lineages: #{go_file}"
  h_go = JSON.parse(File.read(go_file))

  ## get db names (core schemas only; ignore rnaseq/otherfeatures/variation/...)
  h_db_names = {}
  list_folders = [`wget -O - #{base_url}/mysql/`]
  list_kingdoms = ['plants', 'metazoa', 'fungi', 'protists']
  list_kingdoms.each do |e|
    list_folders.push `wget -O - #{base_url2}#{e}/mysql/`
  end
  list_folders.join("\n").split("\n").each do |l|

    puts l
    next unless (m = l.match(/>(\w+)\/</))

    folder = m[1]
    # e.g. homo_sapiens_core_116_38 or foo_bar_core_63_1
    next unless (m_core = folder.match(/\A(.+)_core_(\d+)_\d+\z/))

    ensembl_db_name = m_core[1]
    # Prefer an existing core entry only if somehow duplicated; last core wins.
    h_db_names[ensembl_db_name] = folder
  end

  puts h_db_names.to_json
  
  ensembl_tables = ['transcript', 'translation', 'gene', 'xref', 'object_xref']

  h_ensembl_subdomains_by_id = {}
  h_ensembl_subdomains = {}
  EnsemblSubdomain.all.each do |es|
    h_ensembl_subdomains[es.name.to_sym]= es
    h_ensembl_subdomains_by_id[es.id]= es
  end
    
  #  Organism.all.select{|o| o.id == 35}.each do |o|
  #  Organism.where(:ensembl_db_name => 'aedes_aegypti_lvpagwg').all.each do |o|
  Organism.all.each do |o|
    
    puts "Extract #{o.ensembl_db_name}..."  

    subdomain = h_ensembl_subdomains_by_id[o.ensembl_subdomain_id]
    unless subdomain
      puts "Skip #{o.ensembl_db_name}: missing ensembl_subdomain_id=#{o.ensembl_subdomain_id}"
      next
    end
    es = subdomain.name

    folder_name = h_db_names[o.ensembl_db_name]
    puts o.ensembl_db_name
    puts folder_name
    
    unless folder_name
      puts "Skip #{o.ensembl_db_name}: not found in Ensembl core FTP listing"
      next
    end

    # Release from *_core_<release>_<assembly>, never the first digit in the species name
    # (e.g. cricetulus_griseus_chok1gshd_core_116_1 -> 116, not 1).
    release_num = folder_name[/_core_(\d+)_\d+\z/, 1]
    release_num ||= o.latest_ensembl_release.to_s
    unless release_num.present? && release_num.to_i > 0
      puts "Skip #{o.ensembl_db_name}: cannot determine Ensembl release from #{folder_name}"
      next
    end
    if o.latest_ensembl_release.to_i > 0 && release_num.to_i != o.latest_ensembl_release.to_i
      puts "Note #{o.ensembl_db_name}: core folder release #{release_num} vs organism.latest_ensembl_release #{o.latest_ensembl_release}; using core folder release"
    end
    
    base_dir = ensembl_data_dir
    
    base_dir += es.to_s
    FileUtils.mkdir_p(base_dir) unless File.exist? base_dir
    base_dir += release_num.to_s
    FileUtils.mkdir_p(base_dir) unless File.exist? base_dir
    
    ## get existing Ensembl-sourced gene_sets only (ignore PanglaoDB / Gene Atlas / Flybase)
    ensembl_gs = o.gene_sets.select { |gs| ensembl_gene_set_labels.include?(gs.label) }
    todo_flag = 0
    if ensembl_gs.empty? || ensembl_gs.any? { |gs| gs.latest_ensembl_release.to_i < o.latest_ensembl_release.to_i }
      todo_flag = 1
    end

    if todo_flag == 1
      
      ## delete files if still there
      ensembl_tables.each do |table_name|
        File.delete(tmp_dir + (table_name + ".txt")) if File.exist?(tmp_dir + (table_name + ".txt"))
      end
      
      ###load genes
      puts "Load genes from DB..."
      h_genes = {}
      Gene.where(organism_id: o.id).pluck(:id, :ensembl_id, :ncbi_gene_id).each do |gene_id, ensembl_id, ncbi_gene_id|
        next if ensembl_id.blank?
        h_genes[ensembl_id] = { id: gene_id, ensembl_id: ensembl_id, ncbi_gene_id: ncbi_gene_id }
      end
      
      #      puts "Folder name" + folder_name.to_s
      #      
      #      if folder_name
      #        
      #        puts "Download files from Ensembl..."
      #        ensembl_tables.each do |table_name|
      #          url = base_url + folder_name + "/" + table_name + ".txt.gz"        
      #          cmd = "wget -qO #{tmp_dir}#{table_name}.txt.gz '#{url}'"
      #          `#{cmd}`
      #          #	puts cmd  
      #          
      #          `gunzip #{tmp_dir}#{table_name}.txt.gz`        
      #        end
      #
      
      if folder_name and !folder_name.empty? and !folder_name.match(/_collection$/) # and [:bacteria, :fungi, :protists].include? db_type)                                                                                        
        
        ## delete files if still there                                                                                                                                                                                            
        #        ensembl_tables.each do |table_name|                                                                                                                                                                              
        #          File.delete(tmp_dir + (table_name + ".txt")) if File.exist?(tmp_dir + (table_name + ".txt"))                                                                                                                   
        #        end                                                                                                                                                                                                              
        tmp_dir = base_dir
        db_name = o.ensembl_db_name
        puts "Check archive exists: " + (tmp_dir + "#{db_name}.tgz").to_s
        puts "SIZE: " + File.size(tmp_dir + "#{db_name}.tgz").to_s if File.exist? tmp_dir + "#{db_name}.tgz"
        mysql_base_url = if es.to_s == "vertebrates"
          "#{base_url}mysql/"
        else
          "#{base_url2}#{es}/mysql/"
        end
        if !File.exist? tmp_dir + "#{db_name}.tgz" or File.size(tmp_dir + "#{db_name}.tgz") < 350
            File.delete(tmp_dir + "#{db_name}.tgz") if File.exist?(tmp_dir + "#{db_name}.tgz")
            
            tmp_dir2 = tmp_dir + db_name
            Dir.mkdir tmp_dir2 if !File.exist? tmp_dir2
            
            puts "Delete files if there are some..."
            ensembl_tables.each do |table_name|
              [".txt", ".txt.gz", ".txt.gz.bz2"].each do |ext|
                File.delete(tmp_dir2 + (table_name + ext)) if File.exist?(tmp_dir2 + (table_name + ext))
              end
            end
            
            puts " - Download tables..."
            ensembl_tables.each do |table_name|
              url = mysql_base_url + folder_name + "/" + table_name + ".txt.gz"
              
              if es.to_s == "vertebrates" and release_num.to_i == 89
                `wget -qO #{tmp_dir2}/#{table_name}.txt.gz.bz2 '#{url}'`
                `bunzip2 #{tmp_dir2}/#{table_name}.txt.gz.bz2` if File.exist? "#{tmp_dir2}/#{table_name}.txt.gz.bz2"
              else
                `wget -qO #{tmp_dir2}/#{table_name}.txt.gz '#{url}'`
              end
              gz_file = "#{tmp_dir2}/#{table_name}.txt.gz"
              if File.exist? gz_file
                cmd = "gunzip #{gz_file}"
                puts cmd
                `#{cmd}`
              end
              
            end
        else
          puts "Skipping download, unzipping existing archive..."
          cmd = "cd #{tmp_dir} && tar -zxvf #{db_name}.tgz"
          puts cmd
          `#{cmd}`
          #          ## unzip if still zipped                                                                                                                                                                                     
          #     ensembl_tables.each do |table_name|                                                                                                                                                                               
          #            `gunzip #{tmp_dir}/#{db_name}/#{table_name}.txt.gz` if File.exist? "#{tmp_dir}/#{db_name}/#{table_name}.txt.gz"                                                                                            
          #     end                                                                                                                                                                                                               
        end
        
        tmp_dir+= db_name
        puts "tmp_dir:" + tmp_dir.to_s
        Dir.mkdir tmp_dir if !File.exist? tmp_dir
        tmp_dir = tmp_dir.to_s + "/"
        
        puts "Load data from Ensembl..."
        if File.exist? "#{tmp_dir}xref.txt" and File.exist? "#{tmp_dir}object_xref.txt" and File.exist? "#{tmp_dir}gene.txt"
          
          h_transcript = {}
          if File.exist? "#{tmp_dir}transcript.txt"
            File.open("#{tmp_dir}transcript.txt", "r") do |f|
              while l = f.gets
                t = l.chomp.split("\t")
                h_transcript[t[0]] = t[1]                
              end
            end
          end
          
          h_translation = {}
          if File.exist? "#{tmp_dir}translation.txt"
            File.open("#{tmp_dir}translation.txt", "r") do |f|
              while l = f.gets
                t = l.chomp.split("\t")
                h_translation[t[0]] = t[1]
              end
            end
          end
          
          h_xref = {}
          h_xref_names = {}
          File.open("#{tmp_dir}xref.txt", "r") do |f|
            while l = f.gets
              t = l.chomp.split("\t")
              if h_db_to_load.keys.include? t[1]	  
                splitted_identifier = t[2].split("+")
                xref_acc = (t[1] == '50801') ? ((o.tag || '') + splitted_identifier[0]) : t[2]
                #              puts t[1] + ":" + xref_acc
                #	      if t[1] == '50801'
                #               exit
                #	      end                   
                h_xref[t[0]] = {:acc => xref_acc, :type => t[1], :name => t[5]}
                h_xref_names[t[1]]||={}
                h_xref_names[t[1]][xref_acc] = t[5]
              end
            end
          end
          
          h_object_xref = {}
          h_db_to_load.each_key do |k|
            h_object_xref[k]={}
          end
          #	puts h_object_xref.to_json
          
          File.open("#{tmp_dir}object_xref.txt", "r") do |f|
            while l = f.gets
              t = l.chomp.split("\t")
              if h_xref[t[3]]
                type = h_xref[t[3]][:type]
                if !h_object_xref[type]
                  #     puts type 
                  exit
                end	      
                #	      if t[1] == '458384'
                #                puts [t[1], t[3], type].to_json
                #              end
                gene_ref = t[1]
                if t[2] == 'Transcript'
                  gene_ref = h_transcript[t[1]]
                  #	puts gene_ref
                elsif t[2] == 'Translation'
                  #   gene_ref = h_translation[h_transcript[t[1]]]
                  gene_ref = h_transcript[h_translation[t[1]]]
                  #		puts gene_ref
                end
                h_object_xref[type][gene_ref]||=[]
                h_object_xref[type][gene_ref].push(t[3]) if ! h_object_xref[type][gene_ref].include? t[3]
              end
            end
          end
          
          h_gene = {}
          File.open("#{tmp_dir}gene.txt", "r") do |f|
            while l = f.gets
              t = l.chomp.split("\t")
              h_gene[t[12]]=t[0]
            end
          end
          
          #        h_gene = {}
          #        File.open("#{tmp_dir}external_synonym.txt", "r") do |f|
          #          while l = f.gets
          #            t = l.chomp.split("\t")
          #            h_gene[t[1]]=t[0]
          #          end
          #        end
          
          
          #   puts h_gene.to_json
          #      exit
          
          ### update ncbi genes
          puts "Update NCBI genes..."
          i = 0      
          j = 0
          ncbi_updates = []
          h_gene.each_key do |stable_id|
            g = h_genes[stable_id]
            next unless g
            ox = h_object_xref['1300'][h_gene[stable_id]]
            next unless ox

            j += 1
            new_ncbi = nil
            ox.uniq.each do |xref_id|
              a = h_xref[xref_id]
              next unless a
              new_ncbi = a[:acc]
            end
            next if new_ncbi.nil?
            next if g[:ncbi_gene_id].to_s == new_ncbi.to_s

            ncbi_updates << { id: g[:id], ncbi_gene_id: new_ncbi }
            g[:ncbi_gene_id] = new_ncbi
            i += 1
          end
          flush_ncbi_gene_updates!(ncbi_updates, xref_batch_size)
          puts "  queued NCBI updates: #{ncbi_updates.size}"
          
          #	puts  h_gene.to_json
          #	puts h_object_xref['1000']['458384']
          #exit
          ## create gene_set_items
          puts "Create gene sets..."
          h_gsi = {}
          
          #initialize
          list_db_xrefs.each do |type|
            h_gsi[type] ||={}
          end
          h_gene.each_key do |stable_id|
            g = h_genes[stable_id]
#	  puts "-> " + stable_id.to_s
            list_db_xrefs.each do |type|
              #           puts "Type :" + type
              if ox = h_object_xref[type][h_gene[stable_id]]
                #            puts "toto"
                ox.each do |xref_id|
                  if a = h_xref[xref_id]
                    #  h_gsi[type][o.id] ||={}
                    h_gsi[type][a[:acc]] ||= []
                    h_gsi[type][a[:acc]].push(stable_id)
                    #        puts "Add #{stable_id} to #{a[:acc]}."
                  end
                end
              end
            end
          end
          
          ### stats
          #        h_gsi.each_key do |k|
          #          puts "#{k} : #{h_gsi[k].keys.size} gene set items to update"
          #        end
          
          ### load GO
          puts "Apply lineages for GO annotations..."
          go_type = '1000'
          #        h_gsi[go_type].each_key do |organism_id|
          
          ## add lineage nodes
          list_go_ids = h_gsi[go_type].keys
          list_go_ids.each do |go_id|
            if !h_go[go_id]
              #   puts "1: " + go_id + " : " + h_go[go_id].to_json
              #            exit
            else 
              if !h_go[go_id]["lineage"]
                #    puts "2: " + go_id + " : " + h_go[go_id].to_json
                #              exit
              else
                
                h_go[go_id]["lineage"].each do |lineage_go_id|
                  h_gsi[go_type][lineage_go_id]||=[]
                  h_gsi[go_type][lineage_go_id] |= h_gsi[go_type][go_id]
                end
              end
            end
          end
          
          ### stats
          puts "Stats:"
          h_gsi.each_key do |k|
            puts "#{k} : #{h_gsi[k].keys.size} gene set items to update"
          end
          
          h_gene_sets = {}
          GeneSet.where({:organism_id => o.id}).all.each do |e|
            #    h_gene_sets[e.ref_id]||={}
            h_gene_sets[e.ref_id] = e
          end
          
          h_gene_set_items = {}
          GeneSetItem.where(:gene_set_id => h_gene_sets.keys.map{|k| h_gene_sets[k].id}).all.each do |e|
            h_gene_set_items[e.gene_set_id]||={}
            h_gene_set_items[e.gene_set_id][e.identifier]=e
          end
          
          ActiveRecord::Base.transaction do
            puts "Save new GO in DB..."
            
            list_db_names = h_gsi[go_type].keys.select{|go_id| h_go[go_id]}.map{|go_id| h_go[go_id]["db_name"]}.uniq
            list_db_names.each do |db_name|
              ensure_gene_set!(h_gene_sets, h_db_sets, o, db_name, asap_data_id)
            end
          end
          
          puts "Load GO in DB..."
          go_inserts = []
          go_updates = []
          present_go_by_gene_set_id = Hash.new { |h, k| h[k] = Set.new }
          h_gsi[go_type].each_key do |go_id|
            if h_go[go_id] 
              db_name = h_go[go_id]["db_name"]
              gene_set = h_gene_sets[h_db_sets[db_name].id]
              if gene_set and gene_set.id
                gene_set_item = h_gene_set_items[gene_set.id][go_id] if h_gene_set_items[gene_set.id]
                ensembl_name = h_xref_names[go_type][go_id]
                ensembl_name = nil if ensembl_name.blank? || ensembl_name == "\\N"
                name = ensembl_name.presence || h_go[go_id]['name']
                ensembl_ids = h_gsi[go_type][go_id]
                content = ensembl_ids.select{|ensembl_id| h_genes[ensembl_id]}.map{|ensembl_id| h_genes[ensembl_id][:id]}.uniq.sort.join(",")
                attrs = {
                  gene_set_id: gene_set.id,
                  identifier: go_id,
                  name: name.presence,
                  asap_data_id: asap_data_id,
                  content: content,
                  latest_ensembl_release: o.latest_ensembl_release,
                  obsolete: false
                }
                present_go_by_gene_set_id[gene_set.id] << go_id
                queue_gene_set_item_write!(go_inserts, go_updates, gene_set_item, attrs)
              else
                puts "Gene set for #{db_name} is not found!"
              end
            end
          end
          inserted, updated = flush_gene_set_item_writes!(go_inserts, go_updates, xref_batch_size)
          puts "  GO gene_set_items inserted=#{inserted} updated=#{updated}"

          go_labels = ["GO Biological Processes", "GO Cellular Components", "GO Molecular Functions"]
          go_labels.each do |db_name|
            next unless h_db_sets[db_name]
            gene_set = h_gene_sets[h_db_sets[db_name].id]
            next unless gene_set&.id
            n_obs = mark_missing_gene_set_items_obsolete!(gene_set.id, present_go_by_gene_set_id[gene_set.id])
            puts "  #{db_name}: marked obsolete=#{n_obs}"
            stamp_gene_set_release!(gene_set, o, asap_data_id)
          end
          
          ActiveRecord::Base.transaction do
            list_db_xrefs_direct.select{|type| h_gsi[type].keys.size > 0}.each do |type|
              puts "Save new #{type} in DB..."            
              db_name = h_db_to_load[type][:name]
              ensure_gene_set!(h_gene_sets, h_db_sets, o, db_name, asap_data_id)
            end
          end
          
          list_db_xrefs_direct.each do |type|
            puts "Load #{type} in DB..."            
            db_name = h_db_to_load[type][:name]
            gene_set = h_gene_sets[h_db_sets[db_name].id]

            if gene_set and gene_set.id
              type_inserts = []
              type_updates = []
              present_identifiers = Set.new
              h_gsi[type].each_key do |gsi_id|
                identifier = gsi_id
                gene_set_item = h_gene_set_items[gene_set.id][identifier] if h_gene_set_items[gene_set.id]
                ensembl_ids = h_gsi[type][gsi_id]
                content = ensembl_ids.select{|ensembl_id| h_genes[ensembl_id]}.map{|ensembl_id| h_genes[ensembl_id][:id]}.uniq.join(",")
                attrs = {
                  gene_set_id: gene_set.id,
                  identifier: identifier,
                  name: (h_xref_names[type][gsi_id] != "\\N") ? h_xref_names[type][gsi_id] : nil,
                  asap_data_id: asap_data_id,
                  content: content,
                  latest_ensembl_release: o.latest_ensembl_release,
                  obsolete: false
                }
                present_identifiers << identifier
                queue_gene_set_item_write!(type_inserts, type_updates, gene_set_item, attrs)
              end
              inserted, updated = flush_gene_set_item_writes!(type_inserts, type_updates, xref_batch_size)
              puts "  #{db_name} gene_set_items inserted=#{inserted} updated=#{updated}"
              n_obs = mark_missing_gene_set_items_obsolete!(gene_set.id, present_identifiers)
              puts "  #{db_name}: marked obsolete=#{n_obs}"
              stamp_gene_set_release!(gene_set, o, asap_data_id)
            elsif h_gsi[type].keys.size > 0
              puts "Gene set for #{db_name} not found!"
            elsif gene_set&.id
              stamp_gene_set_release!(gene_set, o, asap_data_id)
            end
          end
          puts "#{j} genes found"
          puts "#{i} genes have been updated!"
          
        else
          puts "Not found #{o.ensembl_db_name}_core"
        end
        
        ensembl_tables.each do |table_name|
          #        File.delete(tmp_dir + (table_name + ".txt")) if File.exist?(tmp_dir + (table_name + ".txt"))
        end
        
      end
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
end
