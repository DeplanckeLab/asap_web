# frozen_string_literal: true

# Per-user storage quota over owned projects (local disk or S3 archive, not both).
# Enforced before create / import / clone for signed-in non-guest users.
# There is no separate project-count cap; storage must leave room for at least
# USER_STORAGE_QUOTA_MIN_PROJECTS projects (default 1) within the byte quota.
class UserStorageQuota
  QUOTA_BYTES = Integer(ENV.fetch('USER_STORAGE_QUOTA_BYTES', 100.gigabytes.to_s))
  MIN_PROJECTS = Integer(ENV.fetch('USER_STORAGE_QUOTA_MIN_PROJECTS', '1'))

  Result = Struct.new(
    :allowed,
    :reason,
    :used_bytes,
    :quota_bytes,
    :additional_bytes,
    :project_count,
    keyword_init: true
  ) do
    def allowed?
      allowed
    end

    def remaining_bytes
      [quota_bytes.to_i - used_bytes.to_i, 0].max
    end

    def used_ratio
      return 0.0 if quota_bytes.to_i <= 0

      [[used_bytes.to_f / quota_bytes.to_f, 0.0].max, 1.0].min
    end

    def used_percent
      (used_ratio * 100).round
    end

    # :ok (<60%), :warn (>=60%), :critical (>=95%)
    def usage_level
      percent = used_percent
      return :critical if percent >= 95
      return :warn if percent >= 60

      :ok
    end
  end

  class << self
    def quota_bytes
      QUOTA_BYTES
    end

    def min_projects
      MIN_PROJECTS
    end

    def applicable?(user)
      user.present? && !user.guest_account?
    end

    # Bytes counted for one project toward the owner's quota.
    # Archived-on-S3 projects use remote size; otherwise local disk_size (with
    # archived size as fallback when local size is missing).
    def project_bytes(project)
      return 0 unless project

      if project.archived_on_s3?
        return project.disk_size_archived.to_i
      end

      local = project.disk_size.to_i
      return local if local.positive?

      project.disk_size_archived.to_i
    end

    def used_bytes(user)
      return 0 unless user

      user.projects.pluck(:archive_status_id, :disk_size, :disk_size_archived).sum do |archive_status_id, disk_size, disk_size_archived|
        if archive_status_id.to_i == 3
          disk_size_archived.to_i
        else
          local = disk_size.to_i
          local.positive? ? local : disk_size_archived.to_i
        end
      end
    end

    def project_count(user)
      return 0 unless user

      user.projects.count
    end

    def status_for(user)
      used = used_bytes(user)
      Result.new(
        allowed: true,
        reason: nil,
        used_bytes: used,
        quota_bytes: quota_bytes,
        additional_bytes: 0,
        project_count: project_count(user)
      )
    end

    def allow?(user, additional_bytes:)
      additional = additional_bytes.to_i
      additional = 0 if additional.negative?

      unless applicable?(user)
        return Result.new(
          allowed: true,
          reason: nil,
          used_bytes: 0,
          quota_bytes: quota_bytes,
          additional_bytes: additional,
          project_count: 0
        )
      end

      used = used_bytes(user)
      count = project_count(user)
      quota = quota_bytes

      if additional > quota
        return deny(
          used: used,
          quota: quota,
          additional: additional,
          count: count,
          reason: "This operation needs #{format_bytes(additional)}, which exceeds the " \
                  "#{format_bytes(quota)} storage quota per user."
        )
      end

      # Users with fewer than MIN_PROJECTS projects may still create one when the
      # new project alone fits the quota, even if existing used bytes are already
      # at or over the cap (e.g. after quota was lowered).
      if count < min_projects && additional <= quota
        return Result.new(
          allowed: true,
          reason: nil,
          used_bytes: used,
          quota_bytes: quota,
          additional_bytes: additional,
          project_count: count
        )
      end

      if used + additional > quota
        return deny(
          used: used,
          quota: quota,
          additional: additional,
          count: count,
          reason: "Storage quota exceeded: you use #{format_bytes(used)} of " \
                  "#{format_bytes(quota)}. This operation needs " \
                  "#{format_bytes(additional)} more. Free space by deleting projects, " \
                  "or use a smaller dataset."
        )
      end

      Result.new(
        allowed: true,
        reason: nil,
        used_bytes: used,
        quota_bytes: quota,
        additional_bytes: additional,
        project_count: count
      )
    end

    def bytes_for_integrate_keys(keys)
      keys = Array(keys).map(&:to_s).reject(&:blank?)
      return 0 if keys.empty?

      Project.where(key: keys).sum { |project| project_bytes(project) }
    end

    def format_bytes(bytes)
      ApplicationController.helpers.display_mem(bytes.to_i)
    end

    private

    def deny(used:, quota:, additional:, count:, reason:)
      Result.new(
        allowed: false,
        reason: reason,
        used_bytes: used,
        quota_bytes: quota,
        additional_bytes: additional,
        project_count: count
      )
    end
  end
end
