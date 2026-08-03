# frozen_string_literal: true

# Lists active CLAs from selected readable projects for the annotations page table.
# When +current_project+ is given, each row includes +in_consensus+ when its consensus
# display label is already present in /col_attrs/_asap_consensus_<type> on that project.
class FederatedAnnotationsQuery
  UNASSIGNED_LABEL = ConsensusAnnotationMetadataExportService::UNASSIGNED_LABEL
  ONTOLOGY_ID_SEPARATOR = ConsensusAnnotationMetadataExportService::ONTOLOGY_ID_SEPARATOR
  CONSENSUS_NAME_PREFIX = '/col_attrs/_asap_consensus_'
  BKP_OR_ONTOLOGY_SUFFIX = /(\.bkp\.\d+|_ontology_term_id)\z/

  class << self
    def call(project_ids:, readable_if:, ontology_term_type_id: nil, current_project: nil)
      new(
        project_ids: project_ids,
        readable_if: readable_if,
        ontology_term_type_id: ontology_term_type_id,
        current_project: current_project
      ).call
    end
  end

  def initialize(project_ids:, readable_if:, ontology_term_type_id: nil, current_project: nil)
    @project_ids = Array(project_ids).map(&:to_i).select(&:positive?).uniq
    @readable_if = readable_if
    @ontology_term_type_id = ontology_term_type_id.present? ? ontology_term_type_id.to_i : nil
    @current_project = current_project
  end

  def call
    return error("readable_if callable is required.") unless @readable_if.respond_to?(:call)
    return error("At least one project is required.") if @project_ids.empty?

    readable_ids = Project.where(id: @project_ids).to_a.select { |project| @readable_if.call(project) }.map(&:id)
    return error("No readable projects selected.") if readable_ids.empty?

    scope = Cla.active
               .where(project_id: readable_ids)
               .includes(:project, :annot, :cell_set, :user, :ontology_term_type, :cla_source)
               .order(Arel.sql('(clas.nber_agree - clas.nber_disagree) DESC, clas.created_at DESC'))
    scope = scope.where(ontology_term_type_id: @ontology_term_type_id) if @ontology_term_type_id&.positive?

    clas = scope.to_a
    cot_info_by_id = load_cot_info(clas)
    consensus_labels_by_type = consensus_labels_by_type_id
    consensus_metadata_by_type = consensus_metadata_links_by_type_id
    type_options = build_type_options(clas)
    metadata_by_type = build_metadata_by_type(clas)

    {
      ok: true,
      annotations: clas.map { |cla| serialize_cla(cla, cot_info_by_id, consensus_labels_by_type) },
      annotation_type_options: type_options,
      annotation_metadata_by_type: metadata_by_type,
      consensus_metadata_by_type: consensus_metadata_by_type
    }
  end

  private

  def error(message)
    {
      ok: false,
      error: message,
      annotations: [],
      annotation_type_options: [],
      annotation_metadata_by_type: {},
      consensus_metadata_by_type: {}
    }
  end

  def build_type_options(clas)
    groups = clas.group_by { |cla| cla.ontology_term_type_id }
    options = groups.map do |type_id, rows|
      ott = rows.first&.ontology_term_type
      {
        id: type_id.nil? ? '' : type_id.to_s,
        tag: ott&.name.to_s,
        label: ott&.label.presence || ott&.name.presence || 'Unspecified',
        count: rows.size
      }
    end
    options.sort_by { |opt| [opt[:id].blank? ? 1 : 0, opt[:label].to_s.downcase] }
  end

  def build_metadata_by_type(clas)
    result = {}
    clas.group_by { |cla| cla.ontology_term_type_id.nil? ? '' : cla.ontology_term_type_id.to_s }.each do |type_id, rows|
      by_annot = rows.group_by(&:annot_id)
      result[type_id] = by_annot.filter_map do |annot_id, annot_rows|
        next if annot_id.blank?

        annot = annot_rows.first&.annot
        {
          id: annot_id,
          label: annot&.display_name.presence || annot&.name.presence || "Annot #{annot_id}",
          count: annot_rows.size
        }
      end.sort_by { |opt| opt[:label].to_s.downcase }
    end
    result
  end

  def consensus_labels_by_type_id
    return {} unless @current_project

    result = {}
    consensus_annots_by_tag.each do |tag, pair|
      ott = ott_by_name[tag]
      next unless ott

      labels = consensus_categories_for(pair[:label_annot])
      next if labels.empty?

      result[ott.id] = labels
    end
    result
  end

  def consensus_metadata_links_by_type_id
    return {} unless @current_project

    result = {}
    type_ids = OntologyTermType.where.not(name: [nil, '']).pluck(:id, :name)
    type_ids.each do |ott_id, name|
      tag = name.to_s.strip
      next if tag.blank?

      label_path = "#{CONSENSUS_NAME_PREFIX}#{tag}"
      ontology_path = "#{label_path}_ontology_term_id"
      pair = consensus_annots_by_tag[tag] || {}
      label_annot = pair[:label_annot]
      ontology_annot = pair[:ontology_annot]

      result[ott_id.to_s] = {
        label: serialize_consensus_link(label_path, label_annot),
        ontology_term_id: serialize_consensus_link(ontology_path, ontology_annot)
      }
    end
    result
  end

  def serialize_consensus_link(path, annot)
    {
      path: path,
      name: path.split('/').last,
      annot_id: annot&.id,
      url: annot ? Rails.application.routes.url_helpers.annot_path(annot) : nil
    }
  end

  def ott_by_name
    @ott_by_name ||= OntologyTermType.all.index_by { |ott| ott.name.to_s }
  end

  def consensus_annots_by_tag
    return @consensus_annots_by_tag if instance_variable_defined?(:@consensus_annots_by_tag)

    @consensus_annots_by_tag =
      if @current_project
        annots = @current_project.annots
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
            by_tag[tag][:ontology_annot] = annot
          else
            tag = name.delete_prefix(CONSENSUS_NAME_PREFIX)
            next if tag.blank? || tag.match?(BKP_OR_ONTOLOGY_SUFFIX)

            by_tag[tag] ||= {}
            by_tag[tag][:label_annot] = annot
          end
        end
        by_tag
      else
        {}
      end
  end

  def consensus_categories_for(annot)
    return Set.new unless annot

    labels = parse_json_list(annot.list_cat_json)
    if labels.empty? && annot.categories_json.present?
      begin
        parsed = JSON.parse(annot.categories_json)
        labels = parsed.keys.map(&:to_s) if parsed.is_a?(Hash)
      rescue JSON::ParserError
        labels = []
      end
    end
    labels.map(&:to_s).reject(&:blank?).reject { |label| label == UNASSIGNED_LABEL }.to_set
  end

  def serialize_cla(cla, cot_info_by_id, consensus_labels_by_type)
    project = cla.project
    consensus_label = display_label_for(cla, cot_info_by_id)
    consensus_labels = consensus_labels_by_type[cla.ontology_term_type_id] || Set.new
    {
      id: cla.id,
      project_id: cla.project_id,
      project_key: project&.key.to_s,
      project_name: project&.name.to_s.presence || project&.key.to_s,
      public_id: project&.public_id,
      ontology_term_type_id: cla.ontology_term_type_id,
      ontology_term_type_label: cla.ontology_term_type&.label.presence || cla.ontology_term_type&.name,
      annot_id: cla.annot_id,
      metadata_name: cla.annot&.display_name.presence || cla.annot&.name.to_s.presence || '-',
      cluster_category: cla.cat.presence || cla.name.presence || '-',
      label: cla.name.presence || '-',
      consensus_label: consensus_label,
      in_consensus: consensus_labels.include?(consensus_label),
      origin: cla.origin_label,
      cell_set_id: cla.cell_set_id,
      cell_set_key: cla.cell_set&.key.to_s,
      nber_agree: cla.nber_agree || 0,
      nber_disagree: cla.nber_disagree || 0,
      score: cla.score,
      created_by: cla.user&.email.to_s.split('@').first.presence || '-',
      created_at: cla.created_at&.strftime('%b %d, %Y'),
      cell_ontology_term_ids: parse_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids),
      up_gene_ids: parse_field(cla.sorted_up_gene_ids.presence || cla.up_gene_ids),
      down_gene_ids: parse_field(cla.sorted_down_gene_ids.presence || cla.down_gene_ids)
    }
  end

  def load_cot_info(clas)
    cot_ids = clas.flat_map do |cla|
      parse_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
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
    cot_ids = parse_field(cla.sorted_cell_ontology_term_ids.presence || cla.cell_ontology_term_ids)
    ontology_labels = cot_ids.filter_map { |cot_id| cot_info_by_id.dig(cot_id.to_s, :label).presence }
    return ontology_labels.join(', ') if ontology_labels.any?

    cla.name.to_s.strip.presence || cla.cat.to_s.strip.presence || 'Unnamed annotation'
  end

  def parse_json_list(value)
    return [] if value.blank?

    parsed = JSON.parse(value.to_s)
    case parsed
    when Array then parsed.map(&:to_s)
    when Hash then parsed.keys.map(&:to_s)
    else []
    end
  rescue JSON::ParserError
    []
  end

  def parse_field(value)
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
end
