# frozen_string_literal: true

require 'yaml'
require 'erb'

namespace :external_catalog do
  class ExternalCatalogSyncSourceBase < ActiveRecord::Base
    self.abstract_class = true
  end

  class ExternalCatalogSyncSourceCandidate < ExternalCatalogSyncSourceBase
    self.table_name = 'external_catalog_candidates'
  end

  def source_app_root_for_external_catalog_sync
    Pathname.new(ENV.fetch('SOURCE_APP_ROOT', '/srv/asap2_test'))
  end

  def source_database_yml_for_external_catalog_sync(source_root)
    direct = source_root + 'config' + 'database.yml'
    nested = source_root + 'src' + 'config' + 'database.yml'
    return direct if File.exist?(direct)
    return nested if File.exist?(nested)

    raise "Missing source database config at #{direct} or #{nested}"
  end

  def source_env_file_for_external_catalog_sync(source_root)
    candidates = [
      source_root + '.env_dev',
      source_root + '.env.test',
      source_root + 'src' + '.env_dev',
      source_root + 'src' + '.env.test'
    ]
    candidates.find { |path| File.exist?(path) }
  end

  def parse_env_file_for_external_catalog_sync(env_file)
    env_map = {}
    File.readlines(env_file).each do |line|
      raw = line.strip
      next if raw.empty? || raw.start_with?('#')

      key, value = raw.split('=', 2)
      next if key.blank?

      cleaned = value.to_s.strip
      if (cleaned.start_with?('"') && cleaned.end_with?('"')) ||
         (cleaned.start_with?("'") && cleaned.end_with?("'"))
        cleaned = cleaned[1..-2]
      end
      env_map[key] = cleaned
    end
    env_map
  end

  def source_db_config_from_env_file_for_external_catalog_sync(source_root)
    env_file = source_env_file_for_external_catalog_sync(source_root)
    return nil if env_file.nil?

    env_values = parse_env_file_for_external_catalog_sync(env_file)
    db_url = env_values['DATABASE_URL'].to_s.strip
    return { url: db_url } if db_url.present? && db_url !~ /@postgres(:|\/)/

    host = ENV.fetch('DEV_DB_HOST', ENV.fetch('SOURCE_DB_HOST', 'host.docker.internal'))
    port = ENV.fetch('DEV_DB_PORT', ENV.fetch('SOURCE_DB_PORT', env_values['POSTGRES_PORT'].presence || '5434'))
    database = env_values['POSTGRES_DB'].to_s.strip
    username = env_values['POSTGRES_USER'].to_s.strip
    password = env_values['POSTGRES_PASSWORD'].to_s.strip
    return nil if [database, username, password].any?(&:blank?)

    {
      adapter: 'postgresql',
      host: host,
      port: port.to_i,
      database: database,
      username: username,
      password: password,
      encoding: 'unicode'
    }
  end

  def source_db_config_for_external_catalog_sync!(source_app_root)
    database_url = ENV['SOURCE_DATABASE_URL'].to_s.strip
    return { url: database_url } if database_url.present?

    dev_postgres_db = ENV['DEV_POSTGRES_DB'].to_s.strip
    if dev_postgres_db.present?
      return {
        adapter: 'postgresql',
        host: ENV.fetch('DEV_DB_HOST', ENV.fetch('SOURCE_DB_HOST', 'postgres')),
        port: ENV.fetch('DEV_DB_PORT', ENV.fetch('SOURCE_DB_PORT', ENV.fetch('POSTGRES_PORT', '5434'))).to_i,
        database: dev_postgres_db,
        username: ENV.fetch('POSTGRES_USER'),
        password: ENV.fetch('POSTGRES_PASSWORD'),
        encoding: 'unicode'
      }
    end

    env_cfg = source_db_config_from_env_file_for_external_catalog_sync(source_app_root)
    return env_cfg if env_cfg.present?

    database_yml = source_database_yml_for_external_catalog_sync(source_app_root)
    raw = ERB.new(File.read(database_yml)).result
    parsed = YAML.safe_load(raw, aliases: true) || {}
    env_key = Rails.env
    env_cfg = parsed[env_key]
    raise "No database config found for env=#{env_key} in #{database_yml}" if env_cfg.blank?

    primary_cfg = env_cfg['primary'] || env_cfg[:primary] || env_cfg
    raise "No primary database config found for env=#{env_key} in #{database_yml}" if primary_cfg.blank?

    primary_cfg.deep_symbolize_keys
  end

  def reset_pk_sequence_for_external_catalog_sync!(table_name)
    quoted_table_name = ActiveRecord::Base.connection.quote(table_name)
    sql = <<~SQL.squish
      SELECT setval(
        pg_get_serial_sequence(#{quoted_table_name}, 'id'),
        COALESCE((SELECT MAX(id) FROM #{table_name}), 0) + 1,
        false
      )
    SQL
    ActiveRecord::Base.connection.execute(sql)
  end

  def prepare_external_catalog_candidate_row(attrs)
    {
      id: attrs['id'],
      source: attrs['source'],
      external_id: attrs['external_id'],
      provider_tag: attrs['provider_tag'],
      title: attrs['title'],
      organism_label: attrs['organism_label'],
      tax_id: attrs['tax_id'],
      project_type_tag: attrs['project_type_tag'].presence || 'sc',
      format_kind: attrs['format_kind'],
      filename: attrs['filename'],
      filesize: attrs['filesize'].to_i,
      url: attrs['url'],
      source_page_url: attrs['source_page_url'],
      dois_json: attrs['dois_json'],
      pmids_json: attrs['pmids_json'],
      identifiers_json: attrs['identifiers_json'],
      attrs_json: attrs['attrs_json'],
      # Import state is environment-local (project/user FKs differ across instances).
      import_status: 'idle',
      import_error: nil,
      import_project_id: nil,
      import_user_id: nil,
      last_seen_at: attrs['last_seen_at'],
      created_at: attrs['created_at'],
      updated_at: attrs['updated_at']
    }
  end

  desc 'Sync external_catalog_candidates from another ASAP instance (dev -> production). ' \
       'Clears import_project_id/import_user_id. DRY_RUN=1. ' \
       'Set DEV_POSTGRES_DB or SOURCE_DATABASE_URL / SOURCE_APP_ROOT.'
  task :sync_from_dev, [:source_app_root] => :environment do |_task, args|
    source_app_root = Pathname.new(
      args[:source_app_root].presence || source_app_root_for_external_catalog_sync.to_s
    )
    dry_run = ENV['DRY_RUN'].to_s.strip == '1'

    unless ActiveRecord::Base.connection.table_exists?(:external_catalog_candidates)
      raise 'external_catalog_candidates table missing on target. Run migrations first.'
    end

    source_config = source_db_config_for_external_catalog_sync!(source_app_root)
    ExternalCatalogSyncSourceBase.establish_connection(source_config)

    unless ExternalCatalogSyncSourceBase.connection.table_exists?(:external_catalog_candidates)
      raise 'external_catalog_candidates table missing on source database.'
    end

    source_rows = ExternalCatalogSyncSourceCandidate.order(:id).map do |row|
      prepare_external_catalog_candidate_row(row.attributes)
    end

    puts "[external_catalog:sync_from_dev] source_app_root=#{source_app_root} " \
         "source_candidates=#{source_rows.size} dry_run=#{dry_run}"

    if dry_run
      by_source = source_rows.group_by { |r| r[:source] }.transform_values(&:size)
      puts "  by_source=#{by_source.inspect}"
      source_rows.first(5).each do |row|
        puts "  - id=#{row[:id]} #{row[:source]}/#{row[:external_id]} " \
             "title=#{row[:title].to_s[0, 60].inspect}"
      end
      puts '  ...' if source_rows.size > 5
      puts '[external_catalog:sync_from_dev] DRY_RUN enabled, no changes applied'
      next
    end

    ActiveRecord::Base.transaction do
      ExternalCatalogCandidate.delete_all
      if source_rows.any?
        source_rows.each_slice(500) do |batch|
          ExternalCatalogCandidate.insert_all!(batch)
        end
      end
      reset_pk_sequence_for_external_catalog_sync!('external_catalog_candidates')
    end

    puts "[external_catalog:sync_from_dev] sync completed successfully " \
         "(#{ExternalCatalogCandidate.count} candidates)"
  ensure
    ExternalCatalogSyncSourceBase.remove_connection if ExternalCatalogSyncSourceBase.connected?
  end
end
