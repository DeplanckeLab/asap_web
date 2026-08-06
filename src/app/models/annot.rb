class Annot < ApplicationRecord
  before_destroy :prevent_deletion_if_locked_from_publication

  # Large JSON payloads that must not be pulled into Puma on project/list pages.
  HEAVY_COLUMNS = %w[headers_json].freeze
  # Refuse to persist header arrays larger than this (guards bad upstream payloads).
  HEADERS_JSON_MAX_SIZE = 10_000

  belongs_to :project
  belongs_to :step, optional: true
  belongs_to :run, optional: true
  belongs_to :data_transformation, optional: true
  belongs_to :data_type, optional: true
  belongs_to :output_attr, optional: true
  belongs_to :user, optional: true
  belongs_to :original_run, class_name: 'Run', foreign_key: 'ori_run_id', optional: true
  belongs_to :sim_step, class_name: 'Step', foreign_key: 'sim_step_id', optional: true
  has_many :annot_cell_sets, dependent: :destroy
  has_many :cell_sets, through: :annot_cell_sets
  has_many :clas, class_name: 'Cla', dependent: :destroy

  after_commit :reindex_project, if: :list_cat_json_previously_changed?

  # Scopes for different types of annotations
  scope :embeddings, -> { where(data_type_id: DataType.where(name: ['umap', 'tsne', 'pca']).pluck(:id)) }
  scope :metadata, -> { where(data_type_id: DataType.where(name: 'metadata').pluck(:id)) }
  scope :expression, -> { where(data_type_id: DataType.where(name: 'expression').pluck(:id)) }
  # Omit heavy JSON columns (notably headers_json) for catalog / list queries.
  # Do not call .count / .sum / other aggregates on this scope: the multi-column
  # select becomes COUNT(col1, col2, ...) on PostgreSQL and raises UndefinedFunction.
  # Use Annot.where(...) (no light) or relation.except(:select).count instead.
  scope :light, -> {
    cols = (column_names - HEAVY_COLUMNS).map { |c| arel_table[c] }
    select(*cols)
  }
  scope :without_heavy_columns, -> { light }

  # Persist only real, bounded header arrays from finish_run metadata. Never synthesize Value N lists.
  def self.headers_json_from_meta(meta)
    return nil unless meta.is_a?(Hash)
    return nil unless meta['nber_rows'].to_i > 0 && meta['nber_cols'].to_i > 0
    return nil if meta['on'] == 'EXPRESSION_MATRIX'

    headers = meta['headers']
    return nil unless headers.is_a?(Array) && headers.any?
    return nil if headers.size > HEADERS_JSON_MAX_SIZE

    headers.to_json
  end

  # headers_json if already selected; otherwise one-row fetch (preview / DE only).
  def headers_json_value
    if has_attribute?('headers_json')
      self[:headers_json]
    else
      self.class.unscoped.where(id: id).pick(:headers_json)
    end
  end

  # Get available embeddings for a project
  def self.available_embeddings(project_id)
    # Find runs that created embeddings
    embedding_runs = Run.joins(:step).where(project_id: project_id, steps: { name: Step::EMBEDDING_STEP_NAMES })
    
    # Get annotations created by those runs
    light.where(project_id: project_id, ori_run_id: embedding_runs.pluck(:id))
      .order(:name)
  end
  
  # Get metadata annotations for a project
  def self.available_metadata(project_id)
    # Find runs that created embeddings
    runs = Run.joins(:step).where(project_id: project_id)
    
    # Get annotations that are NOT created by dimension reduction runs
    light.where(project_id: project_id).order(:name)
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
    embedding_runs = Run.joins(:step).where(project_id: project_id, steps: { name: Step::EMBEDDING_STEP_NAMES })
    
    # Get annotations created by those runs for the specific loom file
    light.where(project_id: project_id, ori_run_id: embedding_runs.pluck(:id), filepath: filepath)
      .order(:name)
  end
  
  # Parse categories from JSON
  def categories
    return [] unless categories_json.present?
    JSON.parse(categories_json) rescue []
  end

  # True when this is a DISCRETE (categorical) annotation whose category
  # names are all numeric-coercible, i.e. safe to re-interpret as NUMERIC.
  # Returns false for any non-DISCRETE annot, for annots with blank or
  # unparseable categories_json, or when any category name is not a number.
  def categorical_numeric_coercible?
    return false unless data_type_id == 3
    return false if categories_json.blank?
    parsed = JSON.parse(categories_json) rescue nil
    return false unless parsed.is_a?(Hash) && !parsed.empty?
    parsed.keys.all? do |key|
      next false if key.nil?
      str = key.to_s.strip
      next false if str.empty?
      !!(Float(str) rescue nil)
    end
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
      # Spatial (Visium) spot coordinates used for the tissue map view.
      if clean_name == 'spatial'
        "Spatial"
      # For embeddings, extract the type and dimensions
      elsif embedding?
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

  # Distinct category labels stored in list_cat_json (per-cell array or label list).
  def distinct_category_labels_from_list_cat_json
    return [] if list_cat_json.blank?

    parsed = JSON.parse(list_cat_json)
    Array(parsed)
      .flat_map { |v| v.to_s.split(' || ') }
      .map { |v| v.strip }
      .reject(&:blank?)
      .uniq
  rescue JSON::ParserError
    []
  end

  # Number of distinct categories for integration batch selection (list_cat_json first).
  def integration_batch_category_count
    labels = distinct_category_labels_from_list_cat_json
    return labels.size if labels.any?

    if categories_json.present?
      cats = JSON.parse(categories_json) rescue {}
      return cats.keys.size if cats.is_a?(Hash) && cats.any?
    end

    nber_cats.to_i
  end

  def integration_batch_metadata?
    integration_batch_category_count > 1
  end

  # Step that produced this annot for downstream ASAP method inputs.
  # Manual sim_step_id on imported data overrides pipeline linkage.
  def effective_source_step_id
    return sim_step_id if sim_step_id.present?

    ori_step_id.presence || step_id.presence || run&.step_id
  end

  def matches_source_step_ids?(source_step_ids)
    return false if source_step_ids.blank?

    ids = source_step_ids.map(&:to_i)
    if sim_step_id.present?
      return ids.include?(sim_step_id)
    end

    return true if step_id.present? && ids.include?(step_id)
    return true if ori_step_id.present? && ids.include?(ori_step_id)

    annot_run = run || (ori_run_id.present? ? original_run : nil)
    annot_run.present? && ids.include?(annot_run.step_id)
  end

  def expression_matrix?
    dim == 3 || name == '/matrix' || name.to_s.start_with?('/layers/')
  end

  def data_class_names
    return [] if data_class_ids.blank?

    @data_class_names ||= data_class_records.map(&:name)
  end

  def data_class_records
    return [] if data_class_ids.blank?

    @data_class_records ||= DataClass.where(id: data_class_ids.split(',').map(&:to_i)).to_a
  end

  def count_matrix?
    expression_matrix? && data_class_names.include?('int_matrix')
  end

  def normalized_matrix?
    expression_matrix? && data_class_names.include?('num_matrix')
  end

  def integer_storage?
    data_class_names.intersect?(%w[int_matrix discrete_mdata])
  end

  def float_storage?
    data_class_names.intersect?(%w[num_matrix numeric_mdata])
  end

  # Human-readable storage type from data_class_ids (e.g. "integer matrix", "cell metadata (float vector)").
  def storage_type_label(project = nil)
    by_name = data_class_records.index_by(&:name)
    return nil if by_name.empty?

    row_label = project&.project_type&.row_label || 'rows'
    col_label = project&.project_type&.col_label || 'columns'
    row_singular = row_label.singularize
    col_singular = col_label.singularize

    apply_template = lambda do |dc|
      template = dc&.label_template
      return nil if template.blank?

      template.gsub('{row_label_singular}', row_singular)
              .gsub('{col_label_singular}', col_singular)
              .gsub('{row_label}', row_label)
              .gsub('{col_label}', col_label)
    end

    if expression_matrix?
      matrix_dc = by_name['int_matrix'] || by_name['num_matrix'] || by_name['matrix']
      matrix_dc ||= DataClass.find_by(name: infer_matrix_data_class_name(by_name))
      label = apply_template.call(matrix_dc)
      return nil if label.blank?

      label = "#{label} vector" if expression_vector_shape?
      return label
    end

    base_dc = by_name['col_mdata'] || by_name['row_mdata'] || by_name['global_mdata'] || by_name['mdata']
    value_dc = by_name['numeric_mdata'] || by_name['discrete_mdata'] || by_name['string_mdata']
    if value_dc.nil?
      inferred_value = infer_metadata_value_data_class_name
      value_dc = DataClass.find_by(name: inferred_value) if inferred_value
    end

    parts = []
    parts << apply_template.call(base_dc) if base_dc
    if value_dc
      value_label = apply_template.call(value_dc)
      shape = metadata_table_shape? ? 'matrix' : 'vector'
      parts << "(#{value_label} #{shape})"
    elsif metadata_table_shape?
      parts << '(matrix)'
    elsif base_dc
      parts << '(vector)'
    end

    label = parts.compact.join(' ').presence
    return label if label.present?

    other = data_class_records.reject { |dc| dc.category == 'skip' || dc.label_template.blank? }
    other.filter_map { |dc| apply_template.call(dc) }.uniq.join(', ').presence
  end

  def matrix_type_label
    storage_type_label
  end

  def data_transformation_label
    return nil unless expression_matrix?

    data_transformation&.label.presence || data_transformation&.name.presence
  end

  private

  def expression_vector_shape?
    nr = nber_rows.to_i
    nc = nber_cols.to_i
    nr.positive? && nc.positive? && (nr == 1 || nc == 1)
  end

  def metadata_table_shape?
    nber_rows.to_i > 1 && nber_cols.to_i > 1
  end

  def infer_matrix_data_class_name(by_name)
    return 'int_matrix' if by_name.key?('int_matrix')
    return 'num_matrix' if by_name.key?('num_matrix')

    data_type&.name == 'NUMERIC' ? 'num_matrix' : 'matrix'
  end

  def infer_metadata_value_data_class_name
    case data_type&.name
    when 'NUMERIC' then 'numeric_mdata'
    when 'DISCRETE', 'CATEGORICAL' then 'discrete_mdata'
    end
  end

  def prevent_deletion_if_locked_from_publication
    return unless project&.locked_from_publication?(self)

    errors.add(:base, 'This metadata was created before publication and cannot be deleted.')
    throw(:abort)
  end

  def reindex_project
    project&.__elasticsearch__&.index_document
  rescue => e
    Rails.logger.warn("[Annot] Reindex failed for project #{project_id}: #{e.message}")
  end
end
