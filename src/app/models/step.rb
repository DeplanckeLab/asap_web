class Step < ApplicationRecord
  has_many :runs, dependent: :destroy
  has_many :annots, through: :runs
  
  # Scopes for different types of steps
  scope :dimension_reduction, -> { where(name: ['dim_reduction', 'pca', 'tsne', 'umap']) }
  scope :clustering, -> { where(name: 'clustering') }
  
  # Check if this step creates embeddings
  def embedding_step?
    name.in?(['dim_reduction', 'pca', 'tsne', 'umap'])
  end
  
  # Check if this step creates clustering
  def clustering_step?
    name == 'clustering'
  end
end
