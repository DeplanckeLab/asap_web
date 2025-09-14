class DataType < ApplicationRecord
  # Associations
  has_many :annots, dependent: :restrict_with_error
  
  # Validations
  validates :name, presence: true, uniqueness: true
  validates :label, presence: true
  
  # Scopes
  scope :embedding_types, -> { where(name: ['umap', 'tsne', 'pca']) }
  scope :metadata_type, -> { where(name: 'metadata') }
  scope :expression_type, -> { where(name: 'expression') }
  
  # Instance methods
  def display_name
    label.presence || name.presence || "Unknown"
  end
  
  def embedding_type?
    ['umap', 'tsne', 'pca'].include?(name)
  end
  
  def metadata_type?
    name == 'metadata'
  end
  
  def expression_type?
    name == 'expression'
  end
end

