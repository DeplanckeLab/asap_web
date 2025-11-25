class Run < ApplicationRecord
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

  scope :dimension_reduction, -> { joins(:step).where(steps: { name: %w[dim_reduction pca tsne umap] }) }
  scope :clustering, -> { joins(:step).where(steps: { name: 'clustering' }) }

  def embedding_run?
    step&.name&.in?(%w[dim_reduction pca tsne umap])
  end

  def clustering_run?
    step&.name == 'clustering'
  end
end
