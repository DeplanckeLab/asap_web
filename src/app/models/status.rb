class Status < ApplicationRecord
  has_many :projects

  validates :name, presence: true

  def display_name
    name
  end

  # User-facing text for run badges (prefer +label+ from DB, then normalize casing).
  # Raw +label+ values are often lowercase (e.g. "success"); +humanize+ yields "Success".
  def ui_label
    raw = self[:label].presence || name.to_s
    raw.to_s.strip.humanize
  end

  def run_badge_bg_class
    case name.to_s.downcase
    when 'pending', 'waiting' then 'bg-yellow-100'
    when 'running' then 'bg-blue-100'
    when 'success' then 'bg-green-100'
    when 'failed' then 'bg-red-100'
    when 'stopped' then 'bg-gray-100'
    else 'bg-gray-100'
    end
  end

  def run_badge_text_class
    case name.to_s.downcase
    when 'pending', 'waiting' then 'text-yellow-800'
    when 'running' then 'text-blue-800'
    when 'success' then 'text-green-800'
    when 'failed' then 'text-red-800'
    when 'stopped' then 'text-gray-800'
    else 'text-gray-800'
    end
  end
end
