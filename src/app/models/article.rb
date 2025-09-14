class Article < ApplicationRecord
  belongs_to :journal, optional: true
  has_many :articles_projects, dependent: :destroy
  has_many :projects, through: :articles_projects
  
  # Scopes
  scope :by_doi, ->(doi) { where(doi: doi) if doi.present? }
  scope :by_pmid, ->(pmid) { where(pmid: pmid) if pmid.present? }
  
  # Instance methods
  def display_title
    title.presence || "Untitled"
  end
  
  def display_authors
    authors.presence || "Unknown authors"
  end
  
  def display_journal
    journal&.name || "Unknown journal"
  end
  
  def display_year
    year.presence || "Unknown year"
  end
  
  def display_reference
    "#{display_authors}. #{display_title}. #{display_journal}. #{display_year}."
  end
end
