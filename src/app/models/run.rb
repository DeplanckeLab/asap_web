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

  private

    def prevent_deletion_if_locked_from_publication
      return unless project&.locked_from_publication?(self)

      errors.add(:base, 'This run was created before publication and cannot be deleted.')
      throw(:abort)
    end
end
