class Run < ApplicationRecord
  belongs_to :project
  belongs_to :step
  belongs_to :user, optional: true
  has_many :annots, dependent: :destroy
  
  # Scopes for different types of runs
  scope :dimension_reduction, -> { joins(:step).where(steps: { name: ['dim_reduction', 'pca', 'tsne', 'umap'] }) }
  scope :clustering, -> { joins(:step).where(steps: { name: 'clustering' }) }
  
  # Check if this run created embeddings
  def embedding_run?
    step&.name.in?(['dim_reduction', 'pca', 'tsne', 'umap'])
  end
  
  # Check if this run created clustering
  def clustering_run?
    step&.name == 'clustering'
  end
end
