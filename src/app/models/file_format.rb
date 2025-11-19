class FileFormat < ApplicationRecord
  scope :ordered, -> { order(Arel.sql("LOWER(name) ASC")) }

  def display_label
    label.presence || name
  end
end


