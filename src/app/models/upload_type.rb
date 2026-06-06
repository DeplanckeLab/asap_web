# frozen_string_literal: true

class UploadType < ApplicationRecord
  def self.id_for(name)
    find_by(name: name)&.id
  end

  def self.name_for(id)
    return if id.blank?

    find_by(id: id)&.name
  end
end
