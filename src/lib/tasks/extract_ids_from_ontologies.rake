desc '####################### extract ids from ontologies'
task extract_ids_from_ontologies: :environment do
  require 'ostruct'
  puts 'Executing...'

  now = Time.now

  data_dir_value = if defined?(APP_CONFIG) && APP_CONFIG.respond_to?(:[])
                     APP_CONFIG[:data_dir]
                   end
  data_dir_value = ENV['DATA_DIR'] if data_dir_value.blank?
  data_dir_value = '/data/asap/' if data_dir_value.blank?
  data_dir = Pathname.new(data_dir_value)
  ontology_dir = data_dir + 'ontologies'
  latest_asap_data_version = 5
  remote_db_version = ENV['ASAP2_REMOTE_DB'].presence
  if remote_db_version.blank?
    configured_versions = if defined?(Asap2RemoteRecord::REMOTE_DB_NAMES)
                            Asap2RemoteRecord::REMOTE_DB_NAMES.map(&:to_s)
                          else
                            []
                          end
    newest_configured = configured_versions
                          .map { |name| [name, name[/\Aasap_data_v(\d+)\z/, 1]&.to_i] }
                          .select { |(_name, ver)| ver.present? }
                          .max_by { |(_name, ver)| ver }
    remote_db_version = newest_configured&.first || "asap_data_v#{latest_asap_data_version}"
  end
  puts "Using remote gene DB: #{remote_db_version}"

  # Normalize ontology references stored in content_json, e.g.
  # - "efo:EFO_0001457" -> "EFO:0001457"
  # - "CL:0002306 {is_inferred=\"true\"}" -> "CL:0002306"
  def normalize_ontology_identifier(raw)
    return nil if raw.nil?

    s = raw.to_s.strip
    s = s.sub(/\s*\{.*\}\s*$/, '')
    s = s.sub(/^efo:EFO_(\d+)$/i, 'EFO:\1')
    s = s.sub(/^obo:(\w+)_(\d+)$/i, '\1:\2')
    if (m = s.match(/^([a-z]+):([A-Za-z]+)_(\d+)$/))
      s = "#{m[2].upcase}:#{m[3]}"
    end
    s
  end

  def extract_identifiers_from_value(value, out = [])
    case value
    when Array
      value.each { |entry| extract_identifiers_from_value(entry, out) }
    when Hash
      value.each_value { |entry| extract_identifiers_from_value(entry, out) }
    else
      str = value.to_s
      return out if str.blank?

      str.scan(/[A-Za-z][A-Za-z0-9_]*:[A-Za-z0-9_]+/).each do |match|
        out << normalize_ontology_identifier(match)
      end
    end
    out
  end

  def cross_ontology_bridge_terms(cot_identifier, h_cot, h_terms, has_native_parent:)
    return [] if has_native_parent

    src_prefix = cot_identifier.to_s.split(':', 2).first&.upcase
    return [] if src_prefix.blank?

    candidates = []
    candidates |= extract_identifiers_from_value(h_cot['xref'])
    candidates |= extract_identifiers_from_value(h_cot['equivalent_to'])
    candidates |= extract_identifiers_from_value(h_cot['consider'])
    candidates |= extract_identifiers_from_value(h_cot['replaced_by'])
    candidates |= extract_identifiers_from_value(h_cot['def'])

    relationship_hash = h_cot['relationship'].is_a?(Hash) ? h_cot['relationship'] : {}
    relationship_hash.each do |rel, values|
      next if rel.to_s == 'part_of'
      candidates |= extract_identifiers_from_value(values)
    end

    candidates
      .compact
      .uniq
      .select { |identifier| h_terms[identifier] }
      .select do |identifier|
        dst_prefix = identifier.to_s.split(':', 2).first&.upcase
        dst_prefix.present? && dst_prefix != src_prefix
      end
  end

  def add_lineage tmp, cur_id, h_parents
    if tmp and cur_id and h_parents and h_parents[cur_id] and h_parents[cur_id].size > 0
      h_parents[cur_id].each do |k|
  #    puts "add #{k} -> #{tmp.to_json}..."
        if !tmp.include? k
          tmp.push k 
          tmp = add_lineage(tmp, k, h_parents)
        end
      end
    end
    return tmp
  end

  ## get all terms by id
  h_co = {}
  CellOntology.all.map{|co| h_co[co.id] = co}
  h_terms = {}
  h_terms2 = {}
  h_parents_by_id = {}
  CellOntologyTerm.all.to_a.select{|cot| co = h_co[cot.cell_ontology_id]; cot.identifier and cot.identifier.match(/^#{co.tag}/)}.each do |cot|
    h_terms[cot.identifier] = cot
    h_terms2[cot.id] = cot
  end

#puts h_terms['CL:0002238'].to_json
#exit
  h_children = {}
  
  CellOntology.all.each do |co|
    
    puts "=> Treating #{co.name}"
      
    ## get genes
    puts " - get genes..."
    h_genes = {}
    organism_ids =  co.organisms.map{|o| o.id}
    organism_ids_i = organism_ids.map(&:to_i).uniq
    if organism_ids_i.any?
      RemoteGene.with_remote(remote_db_version) do
        RemoteGene.where(organism_id: organism_ids_i).pluck(:id, :ensembl_id).each do |id, ensembl_id|
          e = ensembl_id.to_s
          next if e.blank?
          h_genes[e] = OpenStruct.new(id: id.to_i, ensembl_id: e)
        end
      end
    end
    
    cots = co.cell_ontology_terms
 #   h_parents= {}

    if cots
      puts " - update parents and related gene and term ids..."

      ## get all terms     
    #  h_terms = {}
    #  h_terms2 = {}
    #  h_parents_by_id = {}
    #  co.cell_ontology_terms.select{|cot| cot.identifier.match(/^#{co.tag}/) }.each do |cot|
    #    h_terms[cot.identifier] = cot
    #	h_terms2[cot.id] = cot
    #  end
      ## number of terms 
    #  puts "Number of terms: " + h_terms.keys.size

      ## extraction
      co.cell_ontology_terms.each do |cot|
        
        h_related = {:genes => [], :terms => []}
        
        h_cot = Basic.safe_parse_json(cot.content_json, {})
     #    h_parents_by_id[cot.id] = h_cot
        tmp_list = []				
#        tmp_parents = []
        h_cot.each_key do |k|
#          tmp_list = []
          if h_cot[k].is_a? Array
            tmp_list += h_cot[k]
         #   tmp_parents.push 
          elsif h_cot[k].is_a? Hash
            h_cot[k].each_key do |k2|
              if h_cot[k][k2]
                tmp_list += h_cot[k][k2]
              end
            end
          end
        end
        tmp_list.uniq!
        is_a_terms = Array(h_cot["is_a"]).map { |e| normalize_ontology_identifier(e) }
        part_of_terms = Array(h_cot.dig("relationship", "part_of")).map { |e| normalize_ontology_identifier(e) }
        bridge_terms = cross_ontology_bridge_terms(
          cot.identifier,
          h_cot,
          h_terms,
          has_native_parent: is_a_terms.any? || part_of_terms.any?
        )

	h_parents_by_id[cot.id] = is_a_terms.map { |e| h_terms[e]&.id }.compact
        h_parents_by_id[cot.id] |= part_of_terms.map { |e| h_terms[e]&.id }.compact
        h_parents_by_id[cot.id] |= bridge_terms.map { |e| h_terms[e]&.id }.compact

        if is_a_terms.any?
          is_a_terms.select { |e| h_terms[e] and h_terms[cot.identifier] }
                    .map { |e| h_children[h_terms[e].id] ||= []; h_children[h_terms[e].id].push h_terms[cot.identifier].id }
        end
        if part_of_terms.any?
          part_of_terms.select { |e| h_terms[e] and h_terms[cot.identifier] }
                      .map { |e| h_children[h_terms[e].id] ||= []; h_children[h_terms[e].id].push h_terms[cot.identifier].id }
        end
        if bridge_terms.any?
          bridge_terms.select { |e| h_terms[e] and h_terms[cot.identifier] }
                      .map { |e| h_children[h_terms[e].id] ||= []; h_children[h_terms[e].id].push h_terms[cot.identifier].id }
        end
#        h_parents_by_id[cot.id].map{|e| h_children}
        h_upd = {
          :node_gene_ids => tmp_list.map{|e| (h_genes[e]) ? h_genes[e].id : nil}.compact.join(","),          
          :node_term_ids => tmp_list.map{|e| (h_terms[e]) ? h_terms[e].id : nil}.compact.join(","),
          :parent_term_ids => h_parents_by_id[cot.id].join(",") #(h_cot["is_a"]) ? h_cot["is_a"].map{|e| (h_terms[e]) ? h_terms[e].id : nil}.compact.join(",") : ''
        }
        #        h_parents_by_id[cot.id] = h_upd[:parent_term_ids]
        #        h_parents[cot.id] = h_upd[:parent_term_ids]
        puts h_upd.to_json	
        cot.update!(h_upd)
        
      end
      
      #add lineages
      puts " - compute lineages..."
      related_gene_ids = {}
      h_parents_by_id.each_key do |k|
        lineage = add_lineage([], k, h_parents_by_id)
        lineage.each do |e|
       #   h_children[e] ||= []
       #   h_children[e].push k if !h_children[e].include? k
          related_gene_ids[e]||=[]
	  if h_terms2[e]
            #	   h_terms2[e].node_gene_ids.split(',').map{|e2| e2.to_i}.each do |gene_id|
            if h_terms2[e].node_gene_ids
              related_gene_ids[e] += h_terms2[e].node_gene_ids.split(',').map{|e2| e2.to_i} 
            end
          end
        end

        h_upd = {
          :lineage => lineage.join(",")
        }

        h_terms2[k].update!(h_upd) if h_terms2[k]
      
      end

      #compute related gene ids
      
       related_gene_ids.each_key do |k|

        h_upd = {
          :related_gene_ids => related_gene_ids[k].uniq.join(",")
        }

	puts "-#{k}-"
        h_terms2[k].update!(h_upd)

      end


    end


  end
  
  h_children.each_key do |e|
    h_terms2[e].update!(:children_term_ids =>  (h_children[e]) ? h_children[e].join(",") : '')
  end

  
end
