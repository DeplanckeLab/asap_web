desc 'Compute parent_term_ids, lineage, and children_term_ids for all CellOntologyTerms'
task extract_ids_from_ontologies: :environment do
  puts 'Executing...'

  now = Time.now

  def add_lineage(tmp, cur_id, h_parents)
    if tmp && cur_id && h_parents && h_parents[cur_id] && h_parents[cur_id].size > 0
      h_parents[cur_id].each do |k|
        if !tmp.include?(k)
          tmp.push(k)
          tmp = add_lineage(tmp, k, h_parents)
        end
      end
    end
    tmp
  end

  # Normalize identifier references from content_json is_a / part_of values.
  # EFO OBO files store references as "efo:EFO_0030003" while the DB stores
  # them as "EFO:0030003". This method converts such references.
  def normalize_identifier(raw_id)
    # Handle efo:EFO_XXXX -> EFO:XXXX
    if m = raw_id.match(/^efo:EFO_(.+)/)
      return "EFO:#{m[1]}"
    end
    raw_id
  end

  # Build a lookup hash of all terms by identifier (only original terms, i.e.
  # those whose identifier starts with the ontology tag).
  h_co = {}
  CellOntology.all.each { |co| h_co[co.id] = co }

  h_terms = {}
  h_terms2 = {}
  CellOntologyTerm.find_each do |cot|
    co = h_co[cot.cell_ontology_id]
    next unless co && cot.identifier
    next unless cot.identifier.start_with?("#{co.tag}:")
    h_terms[cot.identifier] = cot
    h_terms2[cot.id] = cot
  end

  puts "Loaded #{h_terms.size} original terms across all ontologies."

  h_parents_by_id = {}
  h_children = {}

  # Optionally limit to specific ontology tags via environment variable:
  #   rake extract_ids_from_ontologies ONTOLOGIES=EFO,PATO,MONDO
  filter_tags = ENV['ONTOLOGIES']&.split(',')&.map(&:strip)

  CellOntology.all.each do |co|
    next if filter_tags && !filter_tags.include?(co.tag)

    puts "=> Treating #{co.name} (#{co.tag}, id=#{co.id})"

    cots = co.cell_ontology_terms
    next unless cots

    puts " - update parents and related term ids..."

    cots.find_each do |cot|
      h_cot = begin
        JSON.parse(cot.content_json)
      rescue StandardError
        {}
      end

      # Collect all referenced identifiers from content_json
      tmp_list = []
      h_cot.each_key do |k|
        if h_cot[k].is_a?(Array)
          tmp_list += h_cot[k]
        elsif h_cot[k].is_a?(Hash)
          h_cot[k].each_value do |v|
            tmp_list += v if v.is_a?(Array)
          end
        end
      end
      tmp_list.uniq!
      tmp_list.map! { |e| normalize_identifier(e) }

      # Compute parent_term_ids from is_a and relationship.part_of
      is_a_ids = (h_cot['is_a'] || []).map { |e| normalize_identifier(e) }
      part_of_ids = (h_cot.dig('relationship', 'part_of') || []).map { |e| normalize_identifier(e) }

      parent_ids = is_a_ids.filter_map { |e| h_terms[e]&.id }
      parent_ids |= part_of_ids.filter_map { |e| h_terms[e]&.id }

      h_parents_by_id[cot.id] = parent_ids

      # Build children lookup (inverse of parents)
      if h_terms[cot.identifier]
        is_a_ids.each do |e|
          parent_cot = h_terms[e]
          if parent_cot
            h_children[parent_cot.id] ||= []
            h_children[parent_cot.id].push(h_terms[cot.identifier].id)
          end
        end
        part_of_ids.each do |e|
          parent_cot = h_terms[e]
          if parent_cot
            h_children[parent_cot.id] ||= []
            h_children[parent_cot.id].push(h_terms[cot.identifier].id)
          end
        end
      end

      h_upd = {
        node_term_ids: tmp_list.filter_map { |e| h_terms[e]&.id }.join(','),
        parent_term_ids: parent_ids.join(',')
      }

      cot.update_columns(h_upd)
    end

    # Compute lineages
    puts " - compute lineages..."

    h_parents_by_id.each_key do |k|
      next unless h_terms2[k]
      co_for_term = h_co[h_terms2[k].cell_ontology_id]
      next unless co_for_term && co_for_term.id == co.id

      lineage = add_lineage([], k, h_parents_by_id)
      h_terms2[k].update_columns(lineage: lineage.join(','))
    end
  end

  # Update children_term_ids
  puts " - update children_term_ids..."
  h_children.each_key do |e|
    next unless h_terms2[e]
    h_terms2[e].update_columns(children_term_ids: h_children[e].uniq.join(','))
  end

  elapsed = Time.now - now
  puts "Done in #{elapsed.round(1)}s."
end
