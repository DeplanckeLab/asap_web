# frozen_string_literal: true

require 'shellwords'

# Backfill projects.creator_ip for the latest guest (sandbox) projects using the
# nginx access log client address (X-Real-IP / $remote_addr after real_ip).
#
# Matching rule: first access-log request whose path contains /projects/<key>
# within [created_at - BEFORE_MIN, created_at + AFTER_MIN].
#
# Environment:
#   LIMIT=10                 Number of latest sandbox projects to consider (default 10)
#   DRY_RUN=1                Preview only; do not update
#   FORCE=1                  Overwrite existing creator_ip values
#   ACCESS_LOG=/path/to.log  Nginx access log (default: $DATA_DIR/nginx_logs/asap.epfl.ch.access.log
#                            or /data/asap/nginx_logs/asap.epfl.ch.access.log)
#   BEFORE_MIN=5             Minutes before created_at to accept (default 5)
#   AFTER_MIN=120            Minutes after created_at to accept (default 120)
#   ALLOW_NON_PRODUCTION=1   Required outside production

namespace :projects do
  desc 'Backfill creator_ip for the latest guest sandbox projects from nginx access logs'
  task backfill_guest_creator_ips: :environment do
    unless Rails.env.production?
      unless ENV['ALLOW_NON_PRODUCTION'].to_s == '1'
        puts 'This task is restricted to production. Set ALLOW_NON_PRODUCTION=1 to override.'
        exit 1
      end
    end

    unless Project.column_names.include?('creator_ip')
      puts 'projects.creator_ip column is missing; run migrations first.'
      exit 1
    end

    limit = Integer(ENV.fetch('LIMIT', '10'))
    dry_run = ENV['DRY_RUN'].to_s == '1'
    force = ENV['FORCE'].to_s == '1'
    before_min = Integer(ENV.fetch('BEFORE_MIN', '5'))
    after_min = Integer(ENV.fetch('AFTER_MIN', '120'))

    access_log = ENV['ACCESS_LOG'].presence || begin
      data_dir = ENV['DATA_DIR'].presence || ENV['PROD_DATA_DIR'].presence || '/data/asap'
      File.join(data_dir.to_s.sub(%r{/+\z}, ''), 'nginx_logs', 'asap.epfl.ch.access.log')
    end

    unless File.file?(access_log)
      puts "Access log not found: #{access_log}"
      exit 1
    end

    scope = Project.where(sandbox: true).order(id: :desc).limit(limit)
    scope = scope.where(creator_ip: [nil, '']) unless force
    projects = scope.to_a

    if projects.empty?
      puts 'No guest sandbox projects to backfill.'
      exit 0
    end

    puts "Considering #{projects.size} guest project(s) (LIMIT=#{limit}, FORCE=#{force}, DRY_RUN=#{dry_run})"
    puts "Access log: #{access_log}"

    by_key = projects.index_by(&:key)
    windows = {}
    projects.each do |project|
      created = project.created_at
      windows[project.key] = [
        created - before_min.minutes,
        created + after_min.minutes
      ]
    end

    # Combined grep keeps a single pass over the large access log.
    pattern = projects.map { |p| Regexp.escape("/projects/#{p.key}") }.join('|')
    cmd = ['grep', '-E', pattern, access_log]
    puts "Scanning with: #{cmd.shelljoin}"

    line_re = /\A(\S+) \S+ \S+ \[([^\]]+)\] "(\w+) ([^"]*) HTTP\//
    found = {}

    IO.popen(cmd, err: [:child, :out]) do |io|
      io.each_line do |line|
        m = line_re.match(line)
        next unless m

        ip = m[1]
        stamp = m[2]
        path = m[4].to_s.split(' ', 2).first.to_s

        projects.each do |project|
          key = project.key
          next if found[key]
          next unless path.include?("/projects/#{key}")

          begin
            t = Time.strptime(stamp, '%d/%b/%Y:%H:%M:%S %z')
          rescue ArgumentError
            next
          end

          from_t, to_t = windows[key]
          next if t < from_t || t > to_t

          found[key] = {
            ip: ip,
            at: t,
            path: path
          }
        end

        break if found.size == projects.size
      end
    end

    updated = 0
    missing = 0

    projects.each do |project|
      hit = found[project.key]
      unless hit
        missing += 1
        puts "MISS key=#{project.key} id=#{project.id} created=#{project.created_at} (no log match in window)"
        next
      end

      ip = hit[:ip].to_s.strip
      if ip.blank? || ip == '-'
        missing += 1
        puts "MISS key=#{project.key} id=#{project.id} empty ip in log at #{hit[:at]}"
        next
      end

      previous = project.creator_ip
      puts "HIT  key=#{project.key} id=#{project.id} ip=#{ip} log_at=#{hit[:at]} path=#{hit[:path]} previous=#{previous.inspect}"

      next if dry_run

      project.update_column(:creator_ip, ip)
      updated += 1
    end

    puts "Done. updated=#{updated} missing=#{missing} dry_run=#{dry_run}"
  end
end
