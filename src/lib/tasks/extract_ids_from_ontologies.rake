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

  def normalize_ontology_identifier(raw)
    AsapData::OntologyLineageBridges.normalize_identifier(raw)
  end

  def add_lineage(tmp, cur_id, h_parents)
    if tmp && cur_id && h_parents && h_parents[cur_id] && !h_parents[cur_id].empty?
      h_parents[cur_id].each do |k|
        unless tmp.include?(k)
          tmp.push(k)
          tmp = add_lineage(tmp, k, h_parents)
        end
      end
    end
    tmp
  end

  def record_child!(h_children, parent_id, child_id)
    return if parent_id.blank? || child_id.blank?

    h_children[parent_id] ||= []
    h_children[parent_id].push(child_id) unless h_children[parent_id].include?(child_id)
  end

  ## get all terms by id
  h_co = {}
  CellOntology.all.map { |co| h_co[co.id] = co }
  h_terms = {}
  h_terms2 = {}
  h_parents_by_id = {}
  CellOntologyTerm.all.to_a.select { |cot|
    co = h_co[cot.cell_ontology_id]
    cot.identifier && cot.identifier.match(/^#{co.tag}/)
  }.each do |cot|
    h_terms[cot.identifier] = cot
    h_terms2[cot.id] = cot
  end
  known_identifiers = h_terms.keys.to_set

  h_children = {}
  h_node_gene_ids = {}
  h_node_term_ids = {}

  CellOntology.all.each do |co|
    if ENV['ONTOLOGY_TAG'].present? && co.tag != ENV['ONTOLOGY_TAG']
      puts "=> Skipping #{co.name} (ONTOLOGY_TAG=#{ENV['ONTOLOGY_TAG']})"
      next
    end

    puts "=> Treating #{co.name}"

    ## get genes
    puts ' - get genes...'
    h_genes = {}
    organism_ids = co.organisms.map(&:id)
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
    next unless cots

    puts ' - update parents and related gene and term ids...'

    co.cell_ontology_terms.each do |cot|
      h_cot = Basic.safe_parse_json(cot.content_json, {})
      tmp_list = []
      h_cot.each_key do |k|
        if h_cot[k].is_a?(Array)
          tmp_list += h_cot[k]
        elsif h_cot[k].is_a?(Hash)
          h_cot[k].each_key do |k2|
            tmp_list += h_cot[k][k2] if h_cot[k][k2]
          end
        end
      end
      tmp_list.uniq!

      is_a_terms = Array(h_cot['is_a']).map { |e| normalize_ontology_identifier(e) }
      part_of_terms = AsapData::OntologyLineageBridges.part_of_parent_identifiers(h_cot)
      bridge_terms = AsapData::OntologyLineageBridges.outbound_bridge_terms(
        cot.identifier,
        h_cot,
        known_identifiers,
        has_native_parent: is_a_terms.any? || part_of_terms.any?
      )
      reverse_targets = AsapData::OntologyLineageBridges.reverse_bridge_parent_for(
        cot.identifier,
        h_cot,
        known_identifiers
      )

      parent_ids = []
      parent_ids |= is_a_terms.map { |e| h_terms[e]&.id }.compact
      parent_ids |= part_of_terms.map { |e| h_terms[e]&.id }.compact
      parent_ids |= bridge_terms.map { |e| h_terms[e]&.id }.compact

      h_parents_by_id[cot.id] ||= []
      h_parents_by_id[cot.id] |= parent_ids

      is_a_terms.each do |e|
        next unless h_terms[e] && h_terms[cot.identifier]

        record_child!(h_children, h_terms[e].id, h_terms[cot.identifier].id)
      end
      part_of_terms.each do |e|
        next unless h_terms[e] && h_terms[cot.identifier]

        record_child!(h_children, h_terms[e].id, h_terms[cot.identifier].id)
      end
      bridge_terms.each do |e|
        next unless h_terms[e] && h_terms[cot.identifier]

        record_child!(h_children, h_terms[e].id, h_terms[cot.identifier].id)
      end

      # Collected Uberon xrefs point at species terms: make this term a parent of those targets.
      reverse_targets.each do |target_identifier|
        target = h_terms[target_identifier]
        next unless target

        h_parents_by_id[target.id] ||= []
        h_parents_by_id[target.id] |= [cot.id]
        record_child!(h_children, cot.id, target.id)
      end

      h_node_gene_ids[cot.id] = tmp_list.map { |e| h_genes[e] ? h_genes[e].id : nil }.compact
      h_node_term_ids[cot.id] = tmp_list.map { |e| h_terms[e] ? h_terms[e].id : nil }.compact
    end
  end

  puts ' - write parents, lineages, and related gene ids...'
  related_gene_ids = {}
  h_parents_by_id.each_key do |k|
    parent_ids = Array(h_parents_by_id[k]).uniq
    h_parents_by_id[k] = parent_ids
    lineage = add_lineage([], k, h_parents_by_id)

    lineage.each do |ancestor_id|
      related_gene_ids[ancestor_id] ||= []
      related_gene_ids[ancestor_id] += Array(h_node_gene_ids[ancestor_id])
    end

    next unless h_terms2[k]

    h_terms2[k].update!(
      node_gene_ids: Array(h_node_gene_ids[k]).join(','),
      node_term_ids: Array(h_node_term_ids[k]).join(','),
      parent_term_ids: parent_ids.join(','),
      lineage: lineage.join(',')
    )
  end

  related_gene_ids.each_key do |k|
    next unless h_terms2[k]

    h_terms2[k].update!(related_gene_ids: related_gene_ids[k].uniq.join(','))
  end

  h_children.each_key do |e|
    next unless h_terms2[e]

    h_terms2[e].update!(children_term_ids: Array(h_children[e]).join(','))
  end

  puts "extract_ids_from_ontologies finished in #{(Time.now - now).round(1)}s"
end
