require 'find'
require 'fileutils'
require 'pathname'
namespace :fus do
  def fus_audit_root
    if ENV['UPLOAD_DATA_DIR'].present?
      ENV['UPLOAD_DATA_DIR']
    elsif ENV['DATA_DIR'].present?
      Pathname.new(ENV['DATA_DIR']).join('fus').to_s
    else
      '/data/asap2/fus'
    end
  end

  def fus_audit_bytes_to_human(n)
    n = n.to_i
    return '0 B' if n <= 0

    units = %w[B KB MB GB TB PB]
    idx = 0
    value = n.to_f
    while value >= 1024 && idx < units.size - 1
      value /= 1024.0
      idx += 1
    end
    formatted =
      if idx == 0
        value.to_i.to_s
      else
        format('%.2f', value)
      end
    "#{formatted} #{units[idx]}"
  end

  def fus_audit_dir_size_bytes(path)
    return 0 unless File.exist?(path)

    if File.file?(path)
      return File.size(path).to_i
    end

    total = 0
    Find.find(path.to_s) do |entry|
      next unless File.file?(entry)

      total += File.size(entry).to_i
    rescue StandardError
      next
    end
    total
  end

  desc 'Audit the fus upload tree: list disk usage per Fu id, flag orphans (directory with no Fu row). ' \
       'Dry-run by default (prints would remove for each orphan). Set DELETE_ORPHANS=1 to remove ' \
       'orphan directories only (numeric names under the fus root). ' \
       'Root: UPLOAD_DATA_DIR, else DATA_DIR/fus, else /data/asap2/fus. Override with FUS_ROOT=...'
  task audit: :environment do
    root = Pathname.new(ENV['FUS_ROOT'].presence || fus_audit_root)
    delete_orphans = ENV['DELETE_ORPHANS'].to_s == '1'
    dry_run = !delete_orphans

    unless File.directory?(root.to_s)
      raise "fus root does not exist or is not a directory: #{root}"
    end

    puts "[fus:audit] root=#{root} dry_run=#{dry_run} delete_orphans=#{delete_orphans}"
    puts '[fus:audit] note: this scans the global upload staging root only (UPLOAD_DATA_DIR / DATA_DIR/fus). ' \
         'It does not look at project directories or count symlinks under USER_DATA_DIR.'

    entries = Dir.children(root.to_s)
    numeric_dirs = []
    other = []

    entries.each do |name|
      path = root + name
      if name.match?(/\A\d+\z/) && File.directory?(path.to_s)
        numeric_dirs << name.to_i
      else
        other << [name, path]
      end
    end

    numeric_dirs.sort!

    fus_by_id = numeric_dirs.empty? ? {} : Fu.where(id: numeric_dirs).index_by(&:id)

    orphan_rows = []
    linked_rows = []
    total_bytes = 0
    orphan_bytes = 0

    numeric_dirs.each do |fu_id|
      path = root + fu_id.to_s
      bytes = fus_audit_dir_size_bytes(path.to_s)
      total_bytes += bytes
      fu = fus_by_id[fu_id]
      if fu
        linked_rows << {
          id: fu_id,
          bytes: bytes,
          status: fu.status,
          project_id: fu.project_id,
          upload_file_name: fu.upload_file_name
        }
      else
        orphan_bytes += bytes
        orphan_rows << { id: fu_id, bytes: bytes, path: path.to_s }
      end
    end

    if numeric_dirs.empty?
      missing_scope = Fu.all
    else
      missing_scope = Fu.where.not(id: numeric_dirs)
    end
    missing_total = missing_scope.count
    missing_sample = missing_scope.order(:id).limit(50).pluck(:id)

    puts ''
    puts '[fus:audit] summary'
    puts "  numeric_upload_dirs: #{numeric_dirs.size}"
    puts "  total_size: #{fus_audit_bytes_to_human(total_bytes)} (#{total_bytes} bytes)"
    puts "  orphan_dirs (no Fu row): #{orphan_rows.size}"
    puts "  orphan_size: #{fus_audit_bytes_to_human(orphan_bytes)} (#{orphan_bytes} bytes)"
    puts "  fu_rows_with_dir: #{linked_rows.size}"
    puts "  fu_rows_missing_dir: #{missing_total}"

    if other.any?
      puts ''
      puts '[fus:audit] non-numeric or non-directory entries at root (not classified as orphans):'
      other.each do |name, path|
        type = File.directory?(path.to_s) ? 'dir' : 'file'
        puts "  #{name} (#{type})"
      end
    end

    if orphan_rows.any?
      puts ''
      puts '[fus:audit] orphan directories (no matching Fu id):'
      orphan_rows.sort_by { |r| -r[:bytes] }.each do |r|
        puts "  #{r[:id]}\t#{fus_audit_bytes_to_human(r[:bytes])}\t#{r[:path]}"
      end
    end

    if missing_total.positive?
      puts ''
      puts '[fus:audit] Fu ids in database with no directory under fus root (sample up to 50 ids):'
      missing_sample.each do |id|
        puts "  #{id}"
      end
      if missing_total > missing_sample.size
        puts "  ... (#{missing_total - missing_sample.size} more)"
      end
    end

    if linked_rows.any?
      puts ''
      puts '[fus:audit] directories with Fu rows (sorted by size, top 30):'
      linked_rows.sort_by { |r| -r[:bytes] }.first(30).each do |r|
        puts "  #{r[:id]}\t#{fus_audit_bytes_to_human(r[:bytes])}\tstatus=#{r[:status].inspect}\tproject_id=#{r[:project_id].inspect}\tfile=#{r[:upload_file_name].inspect}"
      end
      puts "  ... (#{linked_rows.size - 30} more rows not shown)" if linked_rows.size > 30
    end

    if dry_run
      puts ''
      if orphan_rows.empty?
        puts '[fus:audit] dry-run: nothing to remove'
      else
        puts "[fus:audit] dry-run: would remove #{orphan_rows.size} orphan director(y|ies)"
        orphan_rows.sort_by { |r| -r[:bytes] }.each do |r|
          puts "  would remove #{r[:path]} (#{fus_audit_bytes_to_human(r[:bytes])})"
        end
        puts '[fus:audit] dry-run only. To delete these paths, re-run with DELETE_ORPHANS=1'
      end
    elsif orphan_rows.empty?
      puts '[fus:audit] DELETE_ORPHANS=1: nothing to remove'
    else
      puts ''
      puts "[fus:audit] DELETE_ORPHANS=1: removing #{orphan_rows.size} orphan director(y|ies)"
      orphan_rows.each do |r|
        FileUtils.rm_rf(r[:path])
        puts "  removed #{r[:path]}"
      rescue StandardError => e
        $stderr.puts "  FAILED #{r[:path]}: #{e.class} #{e.message}"
      end
    end

    puts ''
    puts '[fus:audit] done'
  end
end
