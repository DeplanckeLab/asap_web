# frozen_string_literal: true

require 'set'

# Builds a multi-project consensus preview for one ontology annotation type:
# equal-rank ties per cell set, cell-set collision rows, and optional assignment
# vectors when all ties are resolved (or defaults applied for commit).
class ConsensusAnnotationPreviewService
  UNASSIGNED_LABEL = ConsensusAnnotationMetadataExportService::UNASSIGNED_LABEL
  ONTOLOGY_ID_SEPARATOR = ConsensusAnnotationMetadataExportService::ONTOLOGY_ID_SEPARATOR
  COL_ID_PATHS = ConsensusAnnotationMetadataExportService::COL_ID_PATHS

  class << self
    def call(project:, ontology_term_type_id:, project_ids:, readable_if:, equal_rank_choices: {}, collision_choices: {}, build_vectors: false)
      new(
        project: project,
        ontology_term_type_id: ontology_term_type_id,
        project_ids: project_ids,
        readable_if: readable_if,
        equal_rank_choices: equal_rank_choices,
        collision_choices: collision_choices,
        build_vectors: build_vectors
      ).call
    end
  end

  def initialize(project:, ontology_term_type_id:, project_ids:, readable_if:, equal_rank_choices: {}, collision_choices: {}, build_vectors: false)
    @project = project
    @ontology_term_type_id = ontology_term_type_id.to_i
    @project_ids = Array(project_ids).map(&:to_i).select(&:positive?).uniq
    @readable_if = readable_if
    @equal_rank_choices = normalize_choice_hash(equal_rank_choices)
    @collision_choices = normalize_choice_hash(collision_choices)
    @build_vectors = build_vectors
  end

  def call
    return error("Annotation type is required.") unless @ontology_term_type_id.positive?
    return error("At least one project is required.") if @project_ids.empty?
    return error("readable_if callable is required.") unless @readable_if.respond_to?(:call)

    ontology_term_type = OntologyTermType.find_by(id: @ontology_term_type_id)
    return error("Annotation type not found.") unless ontology_term_type

    tag = ontology_term_type.name.to_s.strip
    return error("Annotation type has no usable tag (name).") if tag.blank?

    readable_ids = readable_project_ids(@project_ids)
    return error("No readable projects selected.") if readable_ids.empty?

    clas = Cla.active
              .where(project_id: readable_ids, ontology_term_type_id: ontology_term_type.id)
              .includes(:cell_set, :annot, :project)
              .to_a
    return error("No annotations found for this annotation type in the selected projects.") if clas.empty?

    cot_info_by_id = load_cot_info(clas)
    cell_set_groups = build_cell_set_groups(clas, cot_info_by_id)
    return error("No cell sets with annotations found for this annotation type.") if cell_set_groups.empty?

    equal_rank = cell_set_groups.select { |group| group[:equal_rank] }.map { |group| serialize_equal_rank(group) }
    unresolved_equal_rank = equal_rank.reject { |row| row[:selected_cla_id].present? }

    winners = resolve_winners(cell_set_groups)
    loom_file = resolve_loom_file(winners)
    return error("Could not determine a loom file for the current project.") if loom_file.blank?

    project_dir = Pathname.new(ENV.fetch("USER_DATA_DIR")) + @project.user_id.to_s + @project.key
    loom_path = project_dir + loom_file
    return error("Loom file not found on disk: #{loom_file}") unless File.exist?(loom_path)

    ensure_current_annot_cell_sets!(loom_file)

    identifiers = first_non_empty_vector(loom_path.to_s, COL_ID_PATHS)
    return error("Could not read cell identifiers from the loom file.") unless identifiers.is_a?(Array) && identifiers.any?

    vector_cache = {}
    prepared = winners.filter_map do |entry|
      indices = cell_indices_for(entry[:cell_set], loom_file, vector_cache, project_dir)
      next if indices.empty?

      entry.merge(indices: indices)
    end.sort_by { |entry| [entry[:nber_cells], entry[:cell_set].id] }

    simulation = simulate_assignment(prepared, identifiers.length, cot_info_by_id)
    collisions = simulation[:collisions]
    consequence_graph = build_consequence_graph(collisions)

    payload = {
      ok: true,
      annotation_type_id: ontology_term_type.id,
      annotation_type_label: ontology_term_type.label.presence || ontology_term_type.name,
      metadata_basename: "_asap_consensus_#{tag}",
      metadata_path: "/col_attrs/_asap_consensus_#{tag}",
      ontology_id_basename: "_asap_consensus_#{tag}_ontology_term_id",
      ontology_id_path: "/col_attrs/_asap_consensus_#{tag}_ontology_term_id",
      loom_file: loom_file.to_s,
      total_cell_count: identifiers.length,
      cell_set_count: prepared.size,
      equal_rank: equal_rank,
      unresolved_equal_rank_count: unresolved_equal_rank.size,
      collisions: collisions.map { |row| row.merge(affects: consequence_graph[row[:id]] || []) },
      collision_count: collisions.size,
      needs_review: unresolved_equal_rank.any? || collisions.any?
    }

    if @build_vectors
      return error("Resolve equal-rank annotation ties before validating.") if unresolved_equal_rank.any?

      vectors = build_assignment_vectors(prepared, identifiers.length, cot_info_by_id)
      return error("No cells could be assigned from the available annotations.") if vectors[:assigned_cell_count].zero?

      payload.merge!(vectors)
    end

    payload
  end

  private

  def error(message)
    { ok: false, error: message }
  end

  def normalize_choice_hash(value)
    case value
    when ActionController::Parameters
      value.to_unsafe_h.transform_keys(&:to_s).transform_values { |v| v.to_s.to_i }
    when Hash
      value.transform_keys(&:to_s).transform_values { |v| v.to_s.to_i }
    else
      {}
    end
  end

  def readable_project_ids(ids)
    Project.where(id: ids).to_a.select { |project| @readable_if.call(project) }.map(&:id)
  end

  def consensus_score(cla)
    (cla.nber_agree || 0) - (cla.nber_disagree || 0)
  end

  def annotation_identity(cla, cot_info_by_id)
    [
      display_label_for(cla, cot_info_by_id),
      ontology_term_id_value_for(cla, cot_info_by_id)
    ].join("\u0001")
  end

  def build_cell_set_groups(clas, cot_info_by_id)
    clas.group_by(&:cell_set_id).filter_map do |cell_set_id, group|
      next if cell_set_id.blank?

      cell_set = group.first&.cell_set
      next unless cell_set

      ranked = group.sort_by { |cla| [-consensus_score(cla), -(cla.created_at&.to_i || 0), -cla.id.to_i] }
      top_score = consensus_score(ranked.first)
      top = ranked.select { |cla| consensus_score(cla) == top_score }
      identities = top.map { |cla| annotation_identity(cla, cot_info_by_id) }.uniq
      equal_rank = identities.size > 1

      {
        cell_set: cell_set,
        cell_set_id: cell_set.id,
        nber_cells: cell_set.nber_cells.to_i,
        candidates: top,
        all_clas: ranked,
        equal_rank: equal_rank,
        top_score: top_score
      }
    end
  end

  def serialize_cla_option(cla, cot_info_by_id, score)
    project = cla.project
    {
      cla_id: cla.id,
      score: score,
      nber_agree: cla.nber_agree || 0,
      nber_disagree: cla.nber_disagree || 0,
      label: display_label_for(cla, cot_info_by_id),
      ontology_term_ids: ontology_term_id_value_for(cla, cot_info_by_id),
      category: cla.cat.presence || cla.name.presence || '-',
      metadata_name: cla.annot&.display_name.presence || cla.annot&.name.to_s.presence || '-',
      project_id: cla.project_id,
      project_key: project&.key.to_s,
      project_name: project&.name.to_s.presence || project&.key.to_s,
      created_at: cla.created_at&.iso8601
    }
  end

  def serialize_equal_rank(group)
    cot_info_by_id = load_cot_info(group[:candidates])
    options = group[:candidates].map { |cla| serialize_cla_option(cla, cot_info_by_id, group[:top_score]) }
    choice = @equal_rank_choices[group[:cell_set_id].to_s].to_i
    selected = choice if choice.positive? && options.any? { |opt| opt[:cla_id] == choice }
    {
      id: "equal_rank:#{group[:cell_set_id]}",
      cell_set_id: group[:cell_set_id],
      cell_set_key: group[:cell_set].key.to_s,
      nber_cells: group[:nber_cells],
      score: group[:top_score],
      candidates: options,
      selected_cla_id: selected
    }
  end

  def resolve_winners(cell_set_groups)
    cell_set_groups.filter_map do |group|
      cla =
        if group[:equal_rank]
          choice_id = @equal_rank_choices[group[:cell_set_id].to_s].to_i
          chosen = group[:candidates].find { |row| row.id == choice_id } if choice_id.positive?
          chosen || group[:candidates].max_by { |row| row.created_at&.to_i || 0 }
        else
          group[:candidates].first
        end
      next unless cla

      {
        cell_set: group[:cell_set],
        cell_set_id: group[:cell_set_id],
        nber_cells: group[:nber_cells],
        cla: cla,
        score: group[:top_score],
        equal_rank: group[:equal_rank]
      }
    end
  end

  def resolve_loom_file(_winners)
    Annot.available_loom_files(@project.id).first
  end

  def ensure_current_annot_cell_sets!(loom_file)
    Annot.where(project_id: @project.id, filepath: loom_file, dim: 1, data_type_id: 3).find_each do |annot|
      Basic.ensure_annot_cell_sets(@project, annot, logger: Rails.logger)
    end
  end

  def cell_indices_for(cell_set, loom_file, vector_cache, project_dir)
    acs_list = AnnotCellSet.where(cell_set_id: cell_set.id, project_id: @project.id).includes(:annot).to_a
    acs = acs_list.find { |row| row.annot&.filepath.to_s == loom_file.to_s } ||
          acs_list.find { |row| row.annot.present? }
    return [] unless acs&.annot

    annot = acs.annot
    list_cats = Basic.safe_parse_json(annot.list_cat_json, [])
    return [] unless list_cats.is_a?(Array)

    category = list_cats[acs.cat_idx.to_i]
    return [] if category.nil?

    values = annot_values(annot, project_dir, vector_cache)
    return [] unless values.is_a?(Array)

    category_s = category.to_s
    values.each_with_index.filter_map do |value, idx|
      idx if value.to_s == category_s
    end
  end

  def annot_values(annot, project_dir, vector_cache)
    cache_key = annot.id
    return vector_cache[cache_key] if vector_cache.key?(cache_key)

    loom_path = project_dir + annot.filepath.to_s
    unless File.exist?(loom_path)
      vector_cache[cache_key] = nil
      return nil
    end

    values = H5DataService.get_metadata_vector(loom_path.to_s, annot.name)
    vector_cache[cache_key] = values.is_a?(Array) ? values : nil
  end

  def first_non_empty_vector(loom_path, paths)
    paths.each do |path|
      values = H5DataService.get_metadata_vector(loom_path, path)
      return values if values.is_a?(Array) && values.any?
    end
    nil
  end

  def simulate_assignment(prepared, total_cells, cot_info_by_id)
    owner = Array.new(total_cells)
    collisions = []

    prepared.each do |entry|
      identity = annotation_identity(entry[:cla], cot_info_by_id)
      overlap_by_owner = Hash.new { |h, key| h[key] = [] }

      entry[:indices].each do |idx|
        next if idx < 0 || idx >= total_cells

        existing = owner[idx]
        next if existing.nil?
        next if existing[:identity] == identity

        overlap_by_owner[existing[:cell_set_id]] << idx
      end

      overwrite_idxs = []
      overlap_by_owner.each do |preferred_cell_set_id, idxs|
        preferred_entry = prepared.find { |row| row[:cell_set_id] == preferred_cell_set_id }
        next unless preferred_entry

        collision_id = "collision:#{preferred_cell_set_id}:#{entry[:cell_set_id]}"
        use_alternative = @collision_choices[collision_id].to_i == 1
        if use_alternative
          overwrite_idxs.concat(idxs)
        end

        collisions << {
          id: collision_id,
          overlap_cell_count: idxs.uniq.size,
          preferred_cell_set_id: preferred_cell_set_id,
          alternative_cell_set_id: entry[:cell_set_id],
          use_alternative: use_alternative,
          preferred: serialize_cla_option(preferred_entry[:cla], cot_info_by_id, preferred_entry[:score]).merge(
            cell_set_id: preferred_cell_set_id,
            cell_set_key: preferred_entry[:cell_set].key.to_s,
            nber_cells: preferred_entry[:nber_cells]
          ),
          alternative: serialize_cla_option(entry[:cla], cot_info_by_id, entry[:score]).merge(
            cell_set_id: entry[:cell_set_id],
            cell_set_key: entry[:cell_set].key.to_s,
            nber_cells: entry[:nber_cells]
          )
        }
      end

      overwrite_set = overwrite_idxs.uniq.to_set
      entry[:indices].each do |idx|
        next if idx < 0 || idx >= total_cells

        if owner[idx].nil? || overwrite_set.include?(idx)
          owner[idx] = {
            cell_set_id: entry[:cell_set_id],
            cla: entry[:cla],
            identity: identity,
            score: entry[:score]
          }
        end
      end
    end

    { collisions: collisions, owner: owner }
  end

  def build_consequence_graph(collisions)
    graph = Hash.new { |h, key| h[key] = [] }
    collisions.each do |left|
      collisions.each do |right|
        next if left[:id] == right[:id]

        left_sets = [left[:preferred_cell_set_id], left[:alternative_cell_set_id]]
        right_sets = [right[:preferred_cell_set_id], right[:alternative_cell_set_id]]
        next if (left_sets & right_sets).empty?

        graph[left[:id]] << right[:id]
      end
    end
    graph.transform_values(&:uniq)
  end

  def build_assignment_vectors(prepared, total_cells, cot_info_by_id)
    labels = Array.new(total_cells, UNASSIGNED_LABEL)
    ontology_term_ids = Array.new(total_cells, UNASSIGNED_LABEL)
    assigned_count = 0

    simulation = simulate_assignment(prepared, total_cells, cot_info_by_id)
    simulation[:owner].each_with_index do |entry, idx|
      next unless entry

      cla = entry[:cla]
      labels[idx] = display_label_for(cla, cot_info_by_id)
      ontology_term_ids[idx] = ontology_term_id_value_for(cla, cot_info_by_id)
      assigned_count += 1
    end

    {
      labels: labels,
      ontology_term_ids: ontology_term_ids,
      assigned_cell_count: assigned_count
    }
  end

  def load_cot_info(clas)
    cot_ids = clas.flat_map do |cla|
      parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
    end.map { |value| value.to_s.to_i }.select(&:positive?).uniq

    return {} if cot_ids.empty?

    cot_info_by_id = {}
    CellOntologyTerm.where(id: cot_ids).pluck(:id, :identifier, :name).each do |id, identifier, name|
      identifier_s = identifier.to_s.strip
      name_s = name.to_s.strip
      next if identifier_s.blank? && name_s.blank?

      cot_info_by_id[id.to_s] = {
        identifier: identifier_s,
        label: name_s.presence || identifier_s
      }
    end
    cot_info_by_id
  end

  def display_label_for(cla, cot_info_by_id)
    cot_ids = parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
    ontology_labels = cot_ids.filter_map { |cot_id| cot_info_by_id.dig(cot_id.to_s, :label).presence }
    return ontology_labels.join(", ") if ontology_labels.any?

    cla.name.to_s.strip.presence || cla.cat.to_s.strip.presence || "Unnamed annotation"
  end

  def ontology_term_id_value_for(cla, cot_info_by_id)
    cot_ids = parse_cla_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
    identifiers = cot_ids.filter_map { |cot_id| cot_info_by_id.dig(cot_id.to_s, :identifier).presence }
    return UNASSIGNED_LABEL if identifiers.empty?

    identifiers.join(ONTOLOGY_ID_SEPARATOR)
  end

  def parse_cla_field(value)
    return [] if value.blank?

    text = value.to_s.strip
    return [] if text.blank?

    candidates =
      begin
        parsed = JSON.parse(text)
        case parsed
        when Array then parsed
        when Hash then parsed.values
        else [parsed]
        end
      rescue JSON::ParserError
        text.tr("[]{}", "").split(/[\s,;|]+/)
      end

    candidates.map { |item| item.to_s.strip }.reject(&:blank?)
  end
end
