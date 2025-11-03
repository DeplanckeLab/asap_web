class Share < ApplicationRecord
  belongs_to :project
  belongs_to :user, optional: true

  # Validations
  validates :project_id, presence: true

  # Permission check methods
  def view_perm?
    view_perm == true
  end

  def analyze_perm?
    analyze_perm == true
  end

  def clone_perm?
    clone_perm == true
  end

  def download_perm?
    download_perm == true
  end

  def export_perm?
    export_perm == true
  end
end

