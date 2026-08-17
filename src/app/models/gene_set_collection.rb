class GeneSetCollection < ApplicationRecord
  belongs_to :project
  belongs_to :user, optional: true
  belongs_to :gene_set_collection_type

  validates :project_id, presence: true
  validates :name, presence: true
  validates :file_key, presence: true, uniqueness: true
  validates :source_kind, presence: true
  validates :gene_set_collection_type_id, presence: true

  def self.imports_dir
    Rails.root.join('tmp', 'gene_set_collection_imports')
  end

  def expected_staged_upload_path
    return if import_id.blank?

    self.class.imports_dir.join("#{project_id}_#{import_id}.gmt").to_s
  end

  def payload_file_path
    project.data_dir + 'gene_set_collections' + "#{file_key}.json"
  end

  def payload_written?
    File.exist?(payload_file_path)
  end
end
