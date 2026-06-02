class Step < ApplicationRecord
  PIPELINE_LABEL_STRATEGY_STD_METHOD_IF_SINGLE_RUN = 'std_method_if_single_run'.freeze

  has_many :runs, dependent: :destroy
  has_many :reqs, dependent: :destroy
  has_many :annots, through: :runs
  has_many :std_methods, dependent: :destroy
  belongs_to :docker_image, optional: true

  # Steps whose runs produce coordinates usable in the visualization view (must match steps.name in DB; extend when new DR step rows are added).
  EMBEDDING_STEP_NAMES = %w[
    dim_reduction
    pca
    tsne
    umap
  ].freeze
  
  # Scopes for different types of steps
  scope :dimension_reduction, -> { where(name: EMBEDDING_STEP_NAMES) }
  scope :clustering, -> { where(name: 'clustering') }
  
  # Check if this step creates embeddings
  def embedding_step?
    EMBEDDING_STEP_NAMES.include?(name.to_s)
  end
  
  # Check if this step creates clustering
  def clustering_step?
    name == 'clustering'
  end

  def label_with_id
    "#{label.presence || name} (#{id})"
  end

  def pipeline_label_for(run = nil)
    strategy = pipeline_label_strategy
    if strategy == PIPELINE_LABEL_STRATEGY_STD_METHOD_IF_SINGLE_RUN && !multiple_runs
      std_method = run&.std_method
      return std_method.label.presence || std_method.name.titleize if std_method
    end

    label.presence || name
  end

  private

  def pipeline_label_strategy
    return nil if attrs_json.blank?

    Basic.safe_parse_json(attrs_json, {})['pipeline_label_strategy']
  end
end
