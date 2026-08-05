# frozen_string_literal: true

# Shared choice gate before replacing discrete metadata:
# - archive: keep previous Annot/loom column as .bkp.N and write new at canonical name
# - delete: cascade-delete dependents, destroy previous Annot/loom column, then write new at canonical name
#
# When previous metadata exists and previous_metadata_policy is blank, returns requires_choice
# with a dependents inventory so the UI can ask the user.
class MetadataRewritePolicyGate
  POLICIES = %w[archive delete].freeze

  class << self
    def call(project:, paths: nil, annots: nil, loom_file: nil, previous_metadata_policy: nil)
      new(
        project: project,
        paths: paths,
        annots: annots,
        loom_file: loom_file,
        previous_metadata_policy: previous_metadata_policy
      ).call
    end
  end

  def initialize(project:, paths: nil, annots: nil, loom_file: nil, previous_metadata_policy: nil)
    @project = project
    @paths = Array(paths).map(&:to_s).reject(&:blank?).uniq
    @annots = Array(annots).compact
    @loom_file = loom_file
    @policy = previous_metadata_policy.to_s.strip.downcase.presence
  end

  def call
    inventories = collect_inventories
    return { ok: true, policy: nil, dependents: nil, cascade: nil } if inventories.empty?

    merged = AnnotDependentsInventory.merge_results(inventories)

    unless POLICIES.include?(@policy)
      return {
        ok: false,
        requires_choice: true,
        dependents: merged,
        options: [
          {
            policy: "archive",
            label: "Keep previous metadata as a backup (.bkp.N)",
            description: "Canonical name gets the new data. Previous Annot keeps its id under a .bkp.N name so dependents stay valid."
          },
          {
            policy: "delete",
            label: "Delete previous metadata and its dependents",
            description: "Removes the previous Annot/loom column and deletes dependent selections/analyses listed below."
          }
        ]
      }
    end

    if @policy == "archive"
      return { ok: true, policy: "archive", dependents: merged, cascade: nil }
    end

    cascade = AnnotDependentsCascade.call(
      project: @project,
      inventories: inventories,
      destroy_annots: true,
      loom_file: @loom_file
    )
    unless cascade[:ok]
      return {
        ok: false,
        error: "Failed to delete previous metadata dependents: #{Array(cascade[:errors]).map { |e| e[:message] }.join('; ')}"
      }
    end

    { ok: true, policy: "delete", dependents: merged, cascade: cascade }
  end

  private

  def collect_inventories
    if @annots.any?
      return @annots.map { |annot| AnnotDependentsInventory.call(project: @project, annot: annot) }
    end

    @paths.filter_map do |path|
      annot = @project.annots.where(name: path, latest_version: true).order(id: :desc).first
      next unless annot

      AnnotDependentsInventory.call(project: @project, annot: annot)
    end
  end
end
