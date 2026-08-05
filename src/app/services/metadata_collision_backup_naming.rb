# frozen_string_literal: true

# Shared naming for collision backups: when new metadata takes a canonical path,
# the previous column is moved to +base.bkp.N+ (N = next free index).
#
# Also recognizes legacy +.vN+ suffixes so reserved-name checks and base stripping
# still work for older archived columns.
module MetadataCollisionBackupNaming
  BKP_SUFFIX_PATTERN = /\.bkp\.(\d+)\z/.freeze
  LEGACY_VERSION_SUFFIX_PATTERN = /\.v\d+\z/.freeze
  # Strip either collision-backup form from the end of a path/name.
  STRIP_SUFFIX_PATTERN = /\.(?:bkp\.\d+|v\d+)\z/.freeze

  module_function

  def strip_suffix(path)
    path.to_s.sub(STRIP_SUFFIX_PATTERN, "")
  end

  def backup?(path)
    path.to_s.match?(BKP_SUFFIX_PATTERN) || path.to_s.match?(LEGACY_VERSION_SUFFIX_PATTERN)
  end

  def format_backup_path(base, index)
    "#{base}.bkp.#{index.to_i}"
  end

  # Next free +base.bkp.N+ for this project (based on existing Annot names).
  def next_path(project, path)
    base = strip_suffix(path)
    existing = Annot.where(project_id: project.id).pluck(:name)
    n = 1
    loop do
      candidate = format_backup_path(base, n)
      return candidate unless existing.include?(candidate)

      n += 1
    end
  end
end
