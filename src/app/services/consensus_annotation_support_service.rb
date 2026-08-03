# frozen_string_literal: true

require 'set'

# Assesses current ASAP consensus metadata on +project+ against active CLAs
# across the clone lineage (same root_project).
#
# Returns per annotation type:
# - error: annotated cells missing from consensus, or consensus not reproducible
# - warning: cells with no annotation at all (with count)
# - success: consensus exists and is compatible with current annotations
class ConsensusAnnotationSupportService
  UNASSIGNED_LABEL = ConsensusAnnotationMetadataExportService::UNASSIGNED_LABEL
  CONSENSUS_NAME_PREFIX = FederatedAnnotationsQuery::CONSENSUS_NAME_PREFIX
  BKP_OR_ONTOLOGY_SUFFIX = FederatedAnnotationsQuery::BKP_OR_ONTOLOGY_SUFFIX
  MAX_EQUAL_RANK_COMBOS = 64
  MAX_COLLISION_COMBOS = 64

  class << self
    def call(project:, readable_if:, user: nil)
      new(project: project, readable_if: readable_if, user: user).call
    end
  end

  def initialize(project:, readable_if:, user: nil)
    @project = project
    @readable_if = readable_if
    @user = user
  end

  def call
    return error('Project is required.') unless @project
    return error('readable_if callable is required.') unless @readable_if.respond_to?(:call)

    lineage = CloneRelatedProjectsQuery.call(
      project: @project,
      scope: 'lineage',
      user: @user,
      readable_if: @readable_if
    )
    return error(lineage[:error] || 'Could not resolve clone lineage.') unless lineage[:ok]

    project_ids = Array(lineage[:projects]).map { |row| row[:id].to_i }.select(&:positive?).uniq
    project_ids = [@project.id] if project_ids.empty?

    by_type = {}
    types_to_check = consensus_types
    lineage_annotation_types(project_ids).each do |ott_id, meta|
      types_to_check[ott_id] ||= meta.merge(label_path: nil, ontology_path: nil)
    end

    types_to_check.each do |ott_id, meta|
      by_type[ott_id.to_s] =
        if meta[:label_path].present?
          check_type(
            ontology_term_type_id: ott_id,
            metadata_path: meta[:label_path],
            ontology_id_path: meta[:ontology_path],
            annotation_type_label: meta[:label],
            project_ids: project_ids
          )
        else
          missing_consensus_result(
            ontology_term_type_id: ott_id,
            annotation_type_label: meta[:label],
            tag: meta[:tag]
          )
        end
    end

    { ok: true, by_type: by_type, project_ids: project_ids }
  end

  private

  def error(message)
    { ok: false, error: message, by_type: {} }
  end

  def lineage_annotation_types(project_ids)
    rows = Cla.active
              .where(project_id: project_ids, cla_source_id: Basic::MANUAL_CLA_SOURCE_ID)
              .left_joins(:ontology_term_type)
              .distinct
              .pluck('clas.ontology_term_type_id', 'ontology_term_types.name', 'ontology_term_types.label')

    result = {}
    rows.each do |ott_id, name, label|
      if ott_id.blank?
        result[nil] ||= {
          tag: '',
          label: 'Unspecified',
          label_path: nil,
          ontology_path: nil
        }
        next
      end

      tag = name.to_s.strip
      next if tag.blank?

      result[ott_id] = {
        tag: tag,
        label: label.presence || name,
        label_path: nil,
        ontology_path: nil
      }
    end
    result
  end

  def missing_consensus_result(ontology_term_type_id:, annotation_type_label:, tag:)
    type_label = annotation_type_label.presence || 'this annotation type'
    if tag.blank?
      message = {
        level: 'error',
        code: 'missing_consensus',
        text: "No consensus annotation exists for annotation type #{type_label}, but ASAP manual annotations are present. " \
              'Assign an annotation type to those annotations before creating consensus metadata.'
      }
      expected_path = nil
      ontology_id_path = nil
    else
      expected_path = "#{CONSENSUS_NAME_PREFIX}#{tag}"
      ontology_id_path = "#{expected_path}_ontology_term_id"
      message = {
        level: 'error',
        code: 'missing_consensus',
        text: "No consensus annotation exists for annotation type #{type_label}, but ASAP manual annotations are present. " \
              "Expected metadata: #{expected_path} and #{ontology_id_path}."
      }
    end
    {
      ontology_term_type_id: ontology_term_type_id,
      annotation_type_label: type_label,
      metadata_path: expected_path,
      ontology_id_path: ontology_id_path,
      status: 'error',
      supported: false,
      messages: [message],
      message: message[:text]
    }
  end

  def consensus_types
    annots = @project.annots
                     .where('name LIKE ?', "#{ActiveRecord::Base.sanitize_sql_like(CONSENSUS_NAME_PREFIX)}%")
                     .to_a
                     .reject { |annot| annot.name.to_s.match?(/\.bkp\.\d+\z/) }

    by_tag = {}
    annots.each do |annot|
      name = annot.name.to_s
      if name.end_with?('_ontology_term_id')
        tag = name.delete_prefix(CONSENSUS_NAME_PREFIX).delete_suffix('_ontology_term_id')
        next if tag.blank?

        by_tag[tag] ||= {}
        by_tag[tag][:ontology_path] = name
      else
        tag = name.delete_prefix(CONSENSUS_NAME_PREFIX)
        next if tag.blank? || tag.match?(BKP_OR_ONTOLOGY_SUFFIX)

        by_tag[tag] ||= {}
        by_tag[tag][:label_path] = name
      end
    end

    ott_by_name = OntologyTermType.where(name: by_tag.keys).index_by { |ott| ott.name.to_s }
    result = {}
    by_tag.each do |tag, paths|
      next if paths[:label_path].blank?

      ott = ott_by_name[tag]
      next unless ott

      result[ott.id] = {
        tag: tag,
        label_path: paths[:label_path],
        ontology_path: paths[:ontology_path],
        label: ott.label.presence || ott.name
      }
    end
    result
  end

  def check_type(ontology_term_type_id:, metadata_path:, ontology_id_path:, annotation_type_label:, project_ids:)
    base = {
      ontology_term_type_id: ontology_term_type_id,
      annotation_type_label: annotation_type_label,
      metadata_path: metadata_path,
      ontology_id_path: ontology_id_path,
      messages: []
    }

    loom_file = Annot.available_loom_files(@project.id).first
    return base.merge(status: 'no_loom') if loom_file.blank?

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    loom_path = project_dir + loom_file
    return base.merge(status: 'loom_missing') unless File.exist?(loom_path)

    stored_labels = read_vector(loom_path.to_s, metadata_path)
    return base.merge(status: 'consensus_unreadable') unless stored_labels.is_a?(Array) && stored_labels.any?
    stored_ontology_ids =
      if ontology_id_path.present?
        read_vector(loom_path.to_s, ontology_id_path)
      end
    stored_ontology_ids = nil unless stored_ontology_ids.is_a?(Array) && stored_ontology_ids.size == stored_labels.size

    total_cells = stored_labels.size
    coverage = annotation_coverage(
      ontology_term_type_id: ontology_term_type_id,
      project_ids: project_ids,
      loom_file: loom_file,
      project_dir: project_dir,
      total_cells: total_cells
    )

    annotated_indexes = coverage[:annotated_indexes]
    unannotated_count = total_cells - annotated_indexes.size
    missing_annotated_count = annotated_indexes.count do |idx|
      stored_labels[idx].to_s == UNASSIGNED_LABEL
    end

    messages = []
    has_error = false

    if missing_annotated_count.positive?
      has_error = true
      messages << {
        level: 'error',
        code: 'annotated_cells_missing_in_consensus',
        count: missing_annotated_count,
        text: "#{missing_annotated_count} cell#{missing_annotated_count == 1 ? '' : 's'} " \
              "with annotations #{missing_annotated_count == 1 ? 'is' : 'are'} missing in the current " \
              "#{annotation_type_label} consensus (#{metadata_path})."
      }
    end

    if unannotated_count.positive?
      messages << {
        level: 'warning',
        code: 'cells_without_annotation',
        count: unannotated_count,
        text: "#{unannotated_count} cell#{unannotated_count == 1 ? '' : 's'} " \
              "ha#{unannotated_count == 1 ? 's' : 've'} no annotation for #{annotation_type_label}."
      }
    end

    reproducibility = assess_reproducibility(
      ontology_term_type_id: ontology_term_type_id,
      annotation_type_label: annotation_type_label,
      metadata_path: metadata_path,
      project_ids: project_ids,
      stored_labels: stored_labels,
      stored_ontology_ids: stored_ontology_ids
    )

    if reproducibility[:level] == 'error'
      has_error = true
      messages << reproducibility[:message]
    elsif reproducibility[:level] == 'success' && !has_error
      messages.unshift(reproducibility[:message])
    end

    status =
      if has_error
        'error'
      elsif messages.any? { |row| row[:level] == 'warning' }
        'warning'
      elsif reproducibility[:level] == 'success'
        'success'
      else
        reproducibility[:status] || 'unknown'
      end

    base.merge(
      status: status,
      supported: !has_error && reproducibility[:level] != 'error',
      annotated_cell_count: annotated_indexes.size,
      unannotated_cell_count: unannotated_count,
      missing_annotated_cell_count: missing_annotated_count,
      total_cell_count: total_cells,
      messages: messages,
      message: messages.map { |row| row[:text] }.join(' ')
    )
  end

  def annotation_coverage(ontology_term_type_id:, project_ids:, loom_file:, project_dir:, total_cells:)
    clas = Cla.active
              .where(project_id: project_ids, ontology_term_type_id: ontology_term_type_id)
              .includes(:cell_set)
              .to_a
    return { annotated_indexes: Set.new } if clas.empty?

    preview = ConsensusAnnotationPreviewService.new(
      project: @project,
      ontology_term_type_id: ontology_term_type_id,
      project_ids: project_ids,
      readable_if: @readable_if
    )
    preview.send(:ensure_current_annot_cell_sets!, loom_file)

    vector_cache = {}
    annotated = Set.new
    clas.map(&:cell_set).compact.uniq(&:id).each do |cell_set|
      preview.send(:cell_indices_for, cell_set, loom_file, vector_cache, project_dir).each do |idx|
        annotated << idx if idx >= 0 && idx < total_cells
      end
    end
    { annotated_indexes: annotated }
  end

  def assess_reproducibility(ontology_term_type_id:, annotation_type_label:, metadata_path:, project_ids:, stored_labels:, stored_ontology_ids:)
    assigned_indexes = stored_labels.each_with_index.filter_map do |label, idx|
      idx if label.to_s != UNASSIGNED_LABEL
    end
    if assigned_indexes.empty?
      return { level: nil, status: 'no_assigned_cells' }
    end

    preview = ConsensusAnnotationPreviewService.call(
      project: @project,
      ontology_term_type_id: ontology_term_type_id,
      project_ids: project_ids,
      readable_if: @readable_if,
      build_vectors: false
    )
    unless preview[:ok]
      return {
        level: 'error',
        status: 'unsupported',
        message: {
          level: 'error',
          code: 'no_source_annotations',
          text: unsupported_message(annotation_type_label, metadata_path)
        }
      }
    end

    if category_unsupported?(stored_labels, ontology_term_type_id, project_ids)
      return {
        level: 'error',
        status: 'unsupported',
        message: {
          level: 'error',
          code: 'labels_not_in_annotations',
          text: unsupported_message(annotation_type_label, metadata_path)
        }
      }
    end

    search = search_reproducing_combination(
      ontology_term_type_id: ontology_term_type_id,
      project_ids: project_ids,
      equal_rank: Array(preview[:equal_rank]),
      stored_labels: stored_labels,
      stored_ontology_ids: stored_ontology_ids
    )

    if search[:matched]
      return {
        level: 'success',
        status: 'reproducible',
        message: {
          level: 'success',
          code: 'compatible',
          text: supported_message(annotation_type_label, metadata_path)
        }
      }
    end

    if search[:exhausted]
      return {
        level: 'error',
        status: 'unsupported',
        message: {
          level: 'error',
          code: 'no_reproducing_combination',
          text: unsupported_message(annotation_type_label, metadata_path)
        }
      }
    end

    {
      level: 'success',
      status: 'not_disproven',
      message: {
        level: 'success',
        code: 'compatible',
        text: supported_message(annotation_type_label, metadata_path)
      }
    }
  end

  def category_unsupported?(stored_labels, ontology_term_type_id, project_ids)
    clas = Cla.active
              .where(project_id: project_ids, ontology_term_type_id: ontology_term_type_id)
              .to_a
    return true if clas.empty?

    cot_info_by_id = load_cot_info(clas)
    source_labels = clas.map { |cla| display_label_for(cla, cot_info_by_id) }.to_set

    stored_labels.any? do |label|
      text = label.to_s
      text != UNASSIGNED_LABEL && !source_labels.include?(text)
    end
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
    return ontology_labels.join(', ') if ontology_labels.any?

    cla.name.to_s.strip.presence || cla.cat.to_s.strip.presence || 'Unnamed annotation'
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
        text.tr('[]{}', '').split(/[\s,;|]+/)
      end

    candidates.map { |item| item.to_s.strip }.reject(&:blank?)
  end

  def search_reproducing_combination(ontology_term_type_id:, project_ids:, equal_rank:, stored_labels:, stored_ontology_ids:)
    choice_lists = Array(equal_rank).map do |row|
      candidates = Array(row[:candidates]).map { |candidate| candidate[:cla_id].to_i }.select(&:positive?)
      candidates = [nil] if candidates.empty?
      [row[:cell_set_id].to_s, candidates]
    end

    equal_rank_combos = enumerate_equal_rank_combos(choice_lists)
    search_exhausted = equal_rank_combos[:exhausted]

    equal_rank_combos[:combos].each do |equal_rank_choices|
      preview = ConsensusAnnotationPreviewService.call(
        project: @project,
        ontology_term_type_id: ontology_term_type_id,
        project_ids: project_ids,
        readable_if: @readable_if,
        equal_rank_choices: equal_rank_choices,
        collision_choices: {},
        build_vectors: true
      )
      next unless preview[:ok]

      if vectors_match?(preview[:labels], stored_labels, preview[:ontology_term_ids], stored_ontology_ids)
        return { matched: true, exhausted: true }
      end

      collision_ids = Array(preview[:collisions]).map { |row| row[:id].to_s }.reject(&:blank?).uniq
      next if collision_ids.empty?

      collision_search = enumerate_collision_combos(collision_ids)
      search_exhausted &&= collision_search[:exhausted]
      collision_search[:combos].each do |collision_choices|
        next if collision_choices.empty?

        with_collisions = ConsensusAnnotationPreviewService.call(
          project: @project,
          ontology_term_type_id: ontology_term_type_id,
          project_ids: project_ids,
          readable_if: @readable_if,
          equal_rank_choices: equal_rank_choices,
          collision_choices: collision_choices,
          build_vectors: true
        )
        next unless with_collisions[:ok]

        if vectors_match?(with_collisions[:labels], stored_labels, with_collisions[:ontology_term_ids], stored_ontology_ids)
          return { matched: true, exhausted: true }
        end
      end
    end

    { matched: false, exhausted: search_exhausted }
  end

  def enumerate_equal_rank_combos(choice_lists)
    return { combos: [{}], exhausted: true } if choice_lists.empty?

    combos = [{}]
    choice_lists.each do |cell_set_id, candidate_ids|
      next_combos = []
      combos.each do |current|
        candidate_ids.each do |cla_id|
          next_combos << (cla_id.nil? ? current.dup : current.merge(cell_set_id => cla_id))
          if next_combos.size >= MAX_EQUAL_RANK_COMBOS
            return { combos: next_combos.first(MAX_EQUAL_RANK_COMBOS), exhausted: false }
          end
        end
      end
      combos = next_combos
    end
    { combos: combos, exhausted: true }
  end

  def enumerate_collision_combos(collision_ids)
    ids = collision_ids.first(6)
    total = 1 << ids.size
    exhausted = ids.size == collision_ids.size && total <= MAX_COLLISION_COMBOS
    limit = [total, MAX_COLLISION_COMBOS].min

    combos = []
    limit.times do |mask|
      choices = {}
      ids.each_with_index do |collision_id, idx|
        choices[collision_id] = 1 if (mask & (1 << idx)).positive?
      end
      combos << choices
    end
    { combos: combos, exhausted: exhausted }
  end

  def vectors_match?(labels, stored_labels, ontology_ids, stored_ontology_ids)
    return false unless labels.is_a?(Array) && stored_labels.is_a?(Array)
    return false unless labels.size == stored_labels.size
    return false unless labels.map(&:to_s) == stored_labels.map(&:to_s)

    return true if stored_ontology_ids.nil?
    return false unless ontology_ids.is_a?(Array) && ontology_ids.size == stored_ontology_ids.size

    ontology_ids.map(&:to_s) == stored_ontology_ids.map(&:to_s)
  end

  def read_vector(loom_path, dataset_path)
    return nil if dataset_path.blank?

    values = H5DataService.get_metadata_vector(loom_path, dataset_path)
    values.is_a?(Array) ? values : nil
  rescue StandardError
    nil
  end

  def unsupported_message(annotation_type_label, metadata_path)
    type_label = annotation_type_label.presence || 'this annotation type'
    path = metadata_path.presence || 'consensus metadata'
    "The current #{type_label} consensus (#{path}) is not supported by existing annotations " \
      "across projects that share the same root project. No combination of those annotations " \
      "can reproduce the current consensus."
  end

  def supported_message(annotation_type_label, metadata_path)
    type_label = annotation_type_label.presence || 'this annotation type'
    path = metadata_path.presence || 'consensus metadata'
    "The current #{type_label} consensus (#{path}) is compatible with existing annotations " \
      "across projects that share the same root project."
  end
end
