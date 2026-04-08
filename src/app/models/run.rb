class Run < ApplicationRecord
  before_destroy :prevent_deletion_if_locked_from_publication

  belongs_to :project
  belongs_to :step
  belongs_to :status, optional: true
  belongs_to :std_method, optional: true
  belongs_to :req, optional: true
  belongs_to :user, optional: true
  belongs_to :job, optional: true

  has_many :annots, dependent: :destroy
  has_many :fos, dependent: :destroy
  has_one :active_run, dependent: :destroy

  scope :dimension_reduction, -> { joins(:step).where(steps: { name: Step::EMBEDDING_STEP_NAMES }) }
  scope :clustering, -> { joins(:step).where(steps: { name: 'clustering' }) }

  def embedding_run?
    step&.embedding_step?
  end

  def clustering_run?
    step&.name == 'clustering'
  end

  # Categorical metadata Annot#id for a FindMarkers run (from attrs_json groups_dataset / groups_filename).
  def marker_metadata_annot_id
    return nil unless step&.name == 'markers'

    h = Basic.safe_parse_json(attrs_json, {})
    gfn = h['groups_filename'] || h[:groups_filename]
    name = h['groups_dataset'] || h[:groups_dataset]
    return nil if gfn.blank? || name.blank?

    pd = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    full = Pathname.new(gfn.to_s)
    rel = full.relative_path_from(pd).to_s
    Annot.find_by(project_id: project_id, name: name.to_s, filepath: rel)&.id
  rescue ArgumentError
    nil
  end

  private

    def prevent_deletion_if_locked_from_publication
      return unless project&.locked_from_publication?(self)

      errors.add(:base, 'This run was created before publication and cannot be deleted.')
      throw(:abort)
    end
end
