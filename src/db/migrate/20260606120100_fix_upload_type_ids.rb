# frozen_string_literal: true

class FixUploadTypeIds < ActiveRecord::Migration[7.1]
  class UploadType < ActiveRecord::Base
    self.table_name = 'upload_types'
  end

  def up
    now = Time.current
    ensure_upload_type!(1, 'project_input', now)
    ensure_upload_type!(2, 'metadata_clipboard', now)
    ensure_upload_type!(3, 'compliance_file_check', now)
  end

  def down
    # no-op
  end

  private

  def ensure_upload_type!(id, name, now)
    by_id = UploadType.find_by(id: id)
    by_name = UploadType.find_by(name: name)

    if by_id && by_id.name == name
      return
    end

    by_name.delete if by_name && by_name.id != id
    by_id.delete if by_id && by_id.name != name

    UploadType.create!(id: id, name: name, created_at: now, updated_at: now) unless UploadType.exists?(id: id)
  end
end
