# frozen_string_literal: true

require 'open3'

# Read-only disk usage report for admin: USER_DATA_DIR + UPLOAD_DATA_DIR + S3 archives.
class StorageUsageReport
  CACHE_KEY = 'storage_usage_report:v4'
  CACHE_TTL = 5.minutes
  DEFAULT_TOP_N = 50

  # Same bucket used by Basic.unarchive / archive.rake for project archives.
  ARCHIVE_S3_BUCKET = {
    key: '20000-af8a16d143d9920a26869b30700c3da4',
    endpoint: 'https://s3.epfl.ch',
    region: 'us-west-2'
  }.freeze

  CATEGORY_LABELS = {
    unarchived_project: 'Unarchived projects',
    archived_project_local_dir: 'Archived projects (local dir still present)',
    orphan_project_dir: 'Orphan project directories (no project row)',
    being_deleted_project: 'Projects marked being_deleted',
    orphan_archive_file: 'Orphan archive .tgz (no project row)',
    archive_file_for_archived_project: 'Archive .tgz for archived projects',
    archive_file_for_unarchived_project: 'Archive .tgz for unarchived projects',
    other_under_users: 'Other files under users',
    orphan_fu: 'Orphan FUs (no Fu row)',
    fu_with_unarchived_project: 'FUs with unarchived associated project',
    fu_with_archived_project: 'FUs with archived associated project',
    fu_without_project: 'FUs without associated project',
    other_under_fus: 'Other files under fus'
  }.freeze

  S3_CATEGORY_LABELS = {
    total: 'Total projects on S3',
    unarchived: 'Backed up on S3, unarchived',
    deleted: 'Backed up on S3, deleted (no project row)',
    archived: 'Archived on S3'
  }.freeze

  Entry = Struct.new(
    :bytes, :category, :path, :user_id, :project_key, :project_id,
    :archive_status_id, :fu_id, :label, :last_active_at,
    keyword_init: true
  )

  class << self
    def call(refresh: false, top_n: DEFAULT_TOP_N)
      new(top_n: top_n).call(refresh: refresh)
    end

    # Classify S3 object inventory against project rows.
    # objects: array of { key:, bytes: }
    # archive_status_by_key: hash of project.key => archive_status_id
    def classify_s3_objects(objects, archive_status_by_key)
      empty = -> { { count: 0, bytes: 0 } }
      stats = {
        total: empty.call,
        unarchived: empty.call,
        deleted: empty.call,
        archived: empty.call
      }

      Array(objects).each do |obj|
        key = obj[:key].to_s
        next if key.blank? || key.end_with?('/')

        bytes = obj[:bytes].to_i
        next if bytes.negative?

        add_s3_stat!(stats[:total], bytes)

        status_id = archive_status_by_key[key]
        category =
          if status_id.nil?
            :deleted
          elsif status_id == 3
            :archived
          else
            :unarchived
          end
        add_s3_stat!(stats[category], bytes)
      end

      {
        bucket: ARCHIVE_S3_BUCKET[:key],
        categories: %i[total unarchived deleted archived].map do |category|
          row = stats[category]
          {
            category: category.to_s,
            label: S3_CATEGORY_LABELS[category],
            count: row[:count],
            bytes: row[:bytes]
          }
        end
      }
    end

    def add_s3_stat!(row, bytes)
      row[:count] += 1
      row[:bytes] += bytes
    end
  end

  def initialize(top_n: DEFAULT_TOP_N)
    @top_n = [top_n.to_i, 1].max
  end

  def call(refresh: false)
    if refresh
      Rails.cache.delete(CACHE_KEY)
    end

    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
      build_report
    end
  end

  private

  def build_report
    users_root = Pathname.new(users_dir)
    fus_root = Pathname.new(fus_dir)

    users_entries = scan_users(users_root)
    fus_entries = scan_fus(fus_root)

    all_entries = users_entries + fus_entries
    categories = summarize_categories(all_entries)

    {
      computed_at: Time.current.iso8601,
      users_dir: users_root.to_s,
      fus_dir: fus_root.to_s,
      filesystems: filesystem_stats([users_root.to_s, fus_root.to_s]),
      categories: categories,
      largest_user_dirs: enrich_user_dirs_with_email(largest_children(users_root, max_depth: 1)),
      largest_fus_dirs: largest_children(fus_root, max_depth: 1),
      top_entries: all_entries.sort_by { |e| -e.bytes }.first(@top_n).map { |e| entry_to_h(e) },
      users_total_bytes: users_entries.sum(&:bytes),
      fus_total_bytes: fus_entries.sum(&:bytes),
      s3: build_s3_section
    }
  end

  def build_s3_section
    objects = list_s3_archive_objects
    keys = objects.map { |o| o[:key] }
    archive_status_by_key = load_archive_status_by_key(keys)
    self.class.classify_s3_objects(objects, archive_status_by_key)
  rescue StandardError => e
    Rails.logger.error("storage_usage_report s3 inventory failed error=#{e.class}: #{e.message}")
    {
      bucket: ARCHIVE_S3_BUCKET[:key],
      error: "#{e.class}: #{e.message}",
      categories: []
    }
  end

  def list_s3_archive_objects
    s3b = ARCHIVE_S3_BUCKET
    h_s3_settings = Basic.get_s3_settings
    client = Basic.connect_s3(s3b, h_s3_settings)

    objects = []
    continuation_token = nil
    loop do
      params = { bucket: s3b[:key] }
      params[:continuation_token] = continuation_token if continuation_token.present?

      response = client.list_objects_v2(params)
      Array(response.contents).each do |obj|
        key = obj.key.to_s
        next if key.blank? || key.end_with?('/')

        objects << { key: key, bytes: obj.size.to_i }
      end

      break unless response.is_truncated

      continuation_token = response.next_continuation_token
      break if continuation_token.blank?
    end
    objects
  end

  def load_archive_status_by_key(keys)
    return {} if keys.empty?

    archive_status_by_key = {}
    keys.uniq.each_slice(1000) do |slice|
      Project.where(key: slice).pluck(:key, :archive_status_id).each do |key, archive_status_id|
        archive_status_by_key[key] = archive_status_id
      end
    end
    archive_status_by_key
  end

  def users_dir
    ENV.fetch('USER_DATA_DIR') do
      raise 'USER_DATA_DIR is not set'
    end
  end

  def fus_dir
    Fu.global_upload_root
  end

  def scan_users(root)
    return [] unless File.directory?(root.to_s)

    size_map = du_size_map(root, max_depth: 2)
    entries = []

    user_dirs = safe_children(root).select { |name| name.match?(/\A\d+\z/) && File.directory?((root + name).to_s) }
    projects_by_user_key = load_projects_by_user_and_key(user_dirs.map(&:to_i))

    user_dirs.each do |user_id_str|
      user_id = user_id_str.to_i
      user_path = root + user_id_str

      safe_children(user_path).each do |entry_name|
        full = user_path + entry_name

        if File.file?(full.to_s) && entry_name.end_with?('.tgz')
          key = entry_name.sub(/\.tgz\z/, '')
          project = projects_by_user_key[[user_id, key]]
          bytes = file_size_bytes(full)
          next if bytes <= 0

          category =
            if project.nil?
              :orphan_archive_file
            elsif project.archived_on_s3?
              :archive_file_for_archived_project
            else
              :archive_file_for_unarchived_project
            end

          entries << Entry.new(
            bytes: bytes,
            category: category,
            path: full.to_s,
            user_id: user_id,
            project_key: key,
            project_id: project&.id,
            archive_status_id: project&.archive_status_id,
            last_active_at: project_last_active_at(project),
            label: entry_name
          )
        elsif File.directory?(full.to_s)
          project_key = entry_name
          project = projects_by_user_key[[user_id, project_key]]
          bytes = size_map[full.to_s] || du_path_bytes(full)
          next if bytes <= 0

          category =
            if project.nil?
              :orphan_project_dir
            elsif project.being_deleted
              :being_deleted_project
            elsif project.archived_on_s3?
              :archived_project_local_dir
            else
              :unarchived_project
            end

          entries << Entry.new(
            bytes: bytes,
            category: category,
            path: full.to_s,
            user_id: user_id,
            project_key: project_key,
            project_id: project&.id,
            archive_status_id: project&.archive_status_id,
            last_active_at: project_last_active_at(project),
            label: "#{user_id}/#{project_key}"
          )
        elsif File.file?(full.to_s)
          bytes = file_size_bytes(full)
          next if bytes <= 0

          entries << Entry.new(
            bytes: bytes,
            category: :other_under_users,
            path: full.to_s,
            user_id: user_id,
            label: "#{user_id}/#{entry_name}"
          )
        end
      end
    end

    entries
  end

  def scan_fus(root)
    return [] unless File.directory?(root.to_s)

    size_map = du_size_map(root, max_depth: 1)
    entries = []

    children = safe_children(root)
    numeric_ids = children.select { |name| name.match?(/\A\d+\z/) && File.directory?((root + name).to_s) }.map(&:to_i)
    fus_by_id = numeric_ids.empty? ? {} : Fu.where(id: numeric_ids).index_by(&:id)
    project_ids = fus_by_id.values.filter_map(&:project_id).uniq
    projects_by_id = project_ids.empty? ? {} : Project.where(id: project_ids).index_by(&:id)

    children.each do |name|
      full = root + name

      if name.match?(/\A\d+\z/) && File.directory?(full.to_s)
        fu_id = name.to_i
        bytes = size_map[full.to_s] || du_path_bytes(full)
        next if bytes <= 0

        fu = fus_by_id[fu_id]
        if fu.nil?
          entries << Entry.new(
            bytes: bytes,
            category: :orphan_fu,
            path: full.to_s,
            fu_id: fu_id,
            label: "fu/#{fu_id}"
          )
          next
        end

        project = fu.project_id.present? ? projects_by_id[fu.project_id] : nil
        category =
          if fu.project_id.blank? || project.nil?
            :fu_without_project
          elsif project.archived_on_s3?
            :fu_with_archived_project
          else
            :fu_with_unarchived_project
          end

        entries << Entry.new(
          bytes: bytes,
          category: category,
          path: full.to_s,
          fu_id: fu_id,
          project_id: project&.id || fu.project_id,
          archive_status_id: project&.archive_status_id,
          user_id: project&.user_id,
          project_key: project&.key,
          last_active_at: project_last_active_at(project),
          label: "fu/#{fu_id}"
        )
      else
        bytes =
          if File.directory?(full.to_s)
            size_map[full.to_s] || du_path_bytes(full)
          else
            file_size_bytes(full)
          end
        next if bytes <= 0

        entries << Entry.new(
          bytes: bytes,
          category: :other_under_fus,
          path: full.to_s,
          label: name
        )
      end
    end

    entries
  end

  def load_projects_by_user_and_key(user_ids)
    return {} if user_ids.empty?

    Project.where(user_id: user_ids).each_with_object({}) do |project, hash|
      hash[[project.user_id, project.key]] = project
    end
  end

  def summarize_categories(entries)
    totals = Hash.new { |h, k| h[k] = { bytes: 0, count: 0 } }
    entries.each do |entry|
      totals[entry.category][:bytes] += entry.bytes
      totals[entry.category][:count] += 1
    end

    totals
      .map do |category, stats|
        {
          category: category.to_s,
          label: CATEGORY_LABELS[category] || category.to_s,
          bytes: stats[:bytes],
          count: stats[:count]
        }
      end
      .sort_by { |row| -row[:bytes] }
  end

  def largest_children(root, max_depth:)
    return [] unless File.directory?(root.to_s)

    size_map = du_size_map(root, max_depth: max_depth)
    root_s = root.to_s.chomp('/')
    depth = max_depth

    size_map
      .reject { |path, bytes| path.chomp('/') == root_s || bytes.to_i <= 0 }
      .select do |path, _|
        rel = path.delete_prefix(root_s).delete_prefix('/')
        rel.split('/').size == depth
      end
      .map { |path, bytes| { path: path, bytes: bytes, label: path.delete_prefix(root_s).delete_prefix('/') } }
      .sort_by { |row| -row[:bytes] }
      .first(@top_n)
  end

  def enrich_user_dirs_with_email(rows)
    user_ids = rows.filter_map { |row| Integer(row[:label], exception: false) }
    emails_by_id = User.where(id: user_ids).pluck(:id, :email).to_h
    rows.map do |row|
      user_id = Integer(row[:label], exception: false)
      row.merge(email: emails_by_id[user_id])
    end
  end

  def filesystem_stats(paths)
    unique_mounts = {}
    paths.uniq.each do |path|
      next unless File.exist?(path)

      stat = df_path(path)
      next unless stat

      unique_mounts[stat[:mounted_on]] ||= stat.merge(paths: [])
      unique_mounts[stat[:mounted_on]][:paths] << path
    end
    unique_mounts.values
  end

  def df_path(path)
    stdout, status = Open3.capture2('df', '-Pk', path.to_s)
    return nil unless status.success?

    lines = stdout.lines.map(&:strip).reject(&:empty?)
    return nil if lines.size < 2

    # Filesystem 1024-blocks Used Available Capacity Mounted on
    parts = lines.last.split(/\s+/)
    return nil if parts.size < 6

    mounted_on = parts[5..].join(' ')
    {
      filesystem: parts[0],
      size_kb: parts[1].to_i,
      used_kb: parts[2].to_i,
      avail_kb: parts[3].to_i,
      capacity: parts[4],
      mounted_on: mounted_on,
      size_bytes: parts[1].to_i * 1024,
      used_bytes: parts[2].to_i * 1024,
      avail_bytes: parts[3].to_i * 1024
    }
  rescue StandardError => e
    Rails.logger.warn("storage_usage_report df failed path=#{path} error=#{e.class}: #{e.message}")
    nil
  end

  # Returns { absolute_path => bytes } using GNU du -k --max-depth=N
  def du_size_map(root, max_depth:)
    stdout, status = Open3.capture2(
      'du', '-k', "--max-depth=#{max_depth.to_i}", root.to_s
    )
    unless status.success?
      Rails.logger.warn("storage_usage_report du failed root=#{root} status=#{status.exitstatus}")
    end

    map = {}
    stdout.each_line do |line|
      kb_s, path = line.strip.split(/\s+/, 2)
      next if path.blank?

      map[path] = kb_s.to_i * 1024
    end
    map
  rescue StandardError => e
    Rails.logger.warn("storage_usage_report du_size_map error=#{e.class}: #{e.message}")
    {}
  end

  def du_path_bytes(path)
    stdout, status = Open3.capture2('du', '-sk', path.to_s)
    return 0 unless status.success?

    stdout.to_s.strip.split(/\s+/, 2).first.to_i * 1024
  rescue StandardError
    0
  end

  def file_size_bytes(path)
    File.size(path.to_s).to_i
  rescue StandardError
    0
  end

  def safe_children(dir)
    Dir.children(dir.to_s).sort
  rescue StandardError => e
    Rails.logger.warn("storage_usage_report list failed dir=#{dir} error=#{e.class}: #{e.message}")
    []
  end

  def entry_to_h(entry)
    {
      bytes: entry.bytes,
      category: entry.category.to_s,
      label: CATEGORY_LABELS[entry.category] || entry.category.to_s,
      path: entry.path,
      user_id: entry.user_id,
      project_key: entry.project_key,
      project_id: entry.project_id,
      archive_status_id: entry.archive_status_id,
      fu_id: entry.fu_id,
      name: entry.label,
      last_active_at: entry.last_active_at&.iso8601
    }
  end

  def project_last_active_at(project)
    return nil if project.nil?

    project.viewed_at || project.updated_at || project.created_at
  end
end
