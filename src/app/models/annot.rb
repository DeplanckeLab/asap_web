class Annot < ApplicationRecord
  belongs_to :project
  belongs_to :step, optional: true
  belongs_to :run, optional: true
  belongs_to :data_type, optional: true
  belongs_to :output_attr, optional: true
  belongs_to :user, optional: true
  belongs_to :original_run, class_name: 'Run', foreign_key: 'ori_run_id', optional: true
  has_many :annot_cell_sets, dependent: :destroy
  has_many :cell_sets, through: :annot_cell_sets
  
  # Scopes for different types of annotations
  scope :embeddings, -> { where(data_type_id: DataType.where(name: ['umap', 'tsne', 'pca']).pluck(:id)) }
  scope :metadata, -> { where(data_type_id: DataType.where(name: 'metadata').pluck(:id)) }
  scope :expression, -> { where(data_type_id: DataType.where(name: 'expression').pluck(:id)) }
  
  # Get available embeddings for a project
  def self.available_embeddings(project_id)
    # Find runs that created embeddings
    embedding_runs = Run.joins(:step).where(project_id: project_id, steps: { name: ['dim_reduction', 'pca', 'tsne', 'umap'] })
    
    # Get annotations created by those runs
    where(project_id: project_id, ori_run_id: embedding_runs.pluck(:id))
      .order(:name)
  end
  
  # Get metadata annotations for a project
  def self.available_metadata(project_id)
    # Find runs that created embeddings
    runs = Run.joins(:step).where(project_id: project_id)
    
    # Get annotations that are NOT created by dimension reduction runs
    where(project_id: project_id).order(:name)
  end
  
  # Get available loom files for a project
  def self.available_loom_files(project_id)
    where(project_id: project_id)
      .where.not(filepath: nil)
      .distinct
      .pluck(:filepath)
      .compact
      .sort
  end
  
  # Get available embeddings for a specific loom file in a project
  def self.available_embeddings_for_loom(project_id, filepath)
    # Find runs that created embeddings
    embedding_runs = Run.joins(:step).where(project_id: project_id, steps: { name: ['dim_reduction', 'pca', 'tsne', 'umap'] })
    
    # Get annotations created by those runs for the specific loom file
    where(project_id: project_id, ori_run_id: embedding_runs.pluck(:id), filepath: filepath)
      .order(:name)
  end
  
  # Parse categories from JSON
  def categories
    return [] unless categories_json.present?
    JSON.parse(categories_json) rescue []
  end
  
  # Parse attributes from JSON
  def attributes_data
    return {} unless attrs_json.present?
    JSON.parse(attrs_json) rescue {}
  end
  
  # Check if this is an embedding
  def embedding?
    return false unless original_run.present?
    original_run.embedding_run?
  end
  
  # Check if this is metadata
  def metadata?
    name.start_with?('/col_attrs/') && !embedding?
  end
  
  # Check if this is clustering
  def clustering?
    return false unless original_run.present?
    original_run.clustering_run?
  end
  
  # Display name for the annotation
  def display_name
    # Extract a clean name from the path
    if name.present?
      # Remove the /col_attrs/ prefix and clean up the name
      clean_name = name.gsub('/col_attrs/', '').gsub('/row_attrs/', '')
      # For embeddings, extract the type and dimensions
      if embedding?
        if clean_name.start_with?('_dr_')
          parts = clean_name.split('_')
          method = parts[2].upcase
          dim = parts[3]
          "#{method} (#{dim})"
        elsif clean_name.start_with?('_umap_')
          parts = clean_name.split('_')
          dim = parts[2]
          "UMAP (#{dim})"
        elsif clean_name.start_with?('_tsne_')
          parts = clean_name.split('_')
          dim = parts[2]
          "t-SNE (#{dim})"
        elsif clean_name.start_with?('_pca_')
          parts = clean_name.split('_')
          dim = parts[2]
          "PCA (#{dim})"
        else
          clean_name
        end
      elsif clustering?
        parts = clean_name.split('_')
        method = parts[2].upcase
        "Clustering (#{method})"
      else
        clean_name
      end
    else
      "Annotation #{id}"
    end
  end
  
  # Get the type of annotation
  def annotation_type
    if embedding?
      'embedding'
    elsif clustering? || (nber_cats.present? && nber_cats.to_i > 0)
      'categorical'
    else
      'continuous'
    end
  end
end
