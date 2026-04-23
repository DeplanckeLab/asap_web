class Status < ApplicationRecord
  has_many :projects

  validates :name, presence: true

  def display_name
    name
  end

  # User-facing text for run badges.
  # The +display_label+ column stores the intended display string (e.g.
  # "Pending", "Stopped"); we fall back to humanizing +name+ only if the column
  # has not been populated for some status row.
  def ui_label
    self[:display_label].presence || name.to_s.strip.humanize
  end

  # Tailwind background class for run badges. Stored in the database so every
  # caller renders the same pill style without duplicating a case/when mapping.
  def run_badge_bg_class
    self[:badge_bg_class].to_s
  end

  # Tailwind text color class for run badges. Same rationale as +run_badge_bg_class+.
  def run_badge_text_class
    self[:badge_text_class].to_s
  end
end
