# frozen_string_literal: true

# Builds cell-level consensus metadata columns from CLAs of one ontology annotation type.
#
# Supports single-project (legacy) and multi-project selection with optional
# equal-rank / collision resolutions from ConsensusAnnotationPreviewService.
#
# Emit:
#   /col_attrs/_asap_consensus_<ontology_term_type.name>
#   /col_attrs/_asap_consensus_<ontology_term_type.name>_ontology_term_id
class ConsensusAnnotationMetadataExportService
  UNASSIGNED_LABEL = "Unassigned"
  ONTOLOGY_ID_SEPARATOR = " || "
  COL_ID_PATHS = ["/col_attrs/_StableID", "/col_attrs/CellID"].freeze

  class << self
    def call(project:, ontology_term_type_id:, project_ids: nil, readable_if: nil, equal_rank_choices: {}, collision_choices: {})
      new(
        project: project,
        ontology_term_type_id: ontology_term_type_id,
        project_ids: project_ids,
        readable_if: readable_if,
        equal_rank_choices: equal_rank_choices,
        collision_choices: collision_choices
      ).call
    end
  end

  def initialize(project:, ontology_term_type_id:, project_ids: nil, readable_if: nil, equal_rank_choices: {}, collision_choices: {})
    @project = project
    @ontology_term_type_id = ontology_term_type_id.to_i
    @project_ids = project_ids
    @readable_if = readable_if
    @equal_rank_choices = equal_rank_choices
    @collision_choices = collision_choices
  end

  def call
    ids = Array(@project_ids).map(&:to_i).select(&:positive?).uniq
    ids = [@project.id] if ids.empty?
    readable_if = @readable_if || ->(_project) { true }

    preview = ConsensusAnnotationPreviewService.call(
      project: @project,
      ontology_term_type_id: @ontology_term_type_id,
      project_ids: ids,
      readable_if: readable_if,
      equal_rank_choices: @equal_rank_choices,
      collision_choices: @collision_choices,
      build_vectors: true
    )
    return preview unless preview[:ok]

    {
      ok: true,
      labels: preview[:labels],
      ontology_term_ids: preview[:ontology_term_ids],
      metadata_basename: preview[:metadata_basename],
      metadata_path: preview[:metadata_path],
      ontology_id_basename: preview[:ontology_id_basename],
      ontology_id_path: preview[:ontology_id_path],
      loom_file: preview[:loom_file],
      annotation_type_id: preview[:annotation_type_id],
      annotation_type_label: preview[:annotation_type_label],
      cell_set_count: preview[:cell_set_count],
      assigned_cell_count: preview[:assigned_cell_count],
      total_cell_count: preview[:total_cell_count],
      equal_rank: preview[:equal_rank],
      collisions: preview[:collisions]
    }
  end
end
