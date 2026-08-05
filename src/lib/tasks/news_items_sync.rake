require 'yaml'
require 'erb'

namespace :news_items do
  class SyncSourceBase < ActiveRecord::Base
    self.abstract_class = true
  end

  class SyncSourceNewsItem < SyncSourceBase
    self.table_name = 'news_items'
  end

  def source_app_root_for_news_items_sync
    Pathname.new(ENV.fetch('SOURCE_APP_ROOT', '/srv/asap2_test'))
  end

  def source_database_yml_for_news_items_sync(source_root)
    direct = source_root + 'config' + 'database.yml'
    nested = source_root + 'src' + 'config' + 'database.yml'
    return direct if File.exist?(direct)
    return nested if File.exist?(nested)

    raise "Missing source database config at #{direct} or #{nested}"
  end

  def source_env_file_for_news_items_sync(source_root)
    candidates = [
      source_root + '.env_dev',
      source_root + '.env.test',
      source_root + 'src' + '.env_dev',
      source_root + 'src' + '.env.test'
    ]
    candidates.find { |path| File.exist?(path) }
  end

  def parse_env_file_for_news_items_sync(env_file)
    env_map = {}
    File.readlines(env_file).each do |line|
      raw = line.strip
      next if raw.empty? || raw.start_with?('#')

      key, value = raw.split('=', 2)
      next if key.blank?

      cleaned = value.to_s.strip
      if (cleaned.start_with?('"') && cleaned.end_with?('"')) || (cleaned.start_with?("'") && cleaned.end_with?("'"))
        cleaned = cleaned[1..-2]
      end
      env_map[key] = cleaned
    end
    env_map
  end

  def source_db_config_from_env_file_for_news_items_sync(source_root)
    env_file = source_env_file_for_news_items_sync(source_root)
    return nil if env_file.nil?

    env_values = parse_env_file_for_news_items_sync(env_file)
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

  def source_db_config_for_news_items_sync!(source_app_root)
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

    env_cfg = source_db_config_from_env_file_for_news_items_sync(source_app_root)
    return env_cfg if env_cfg.present?

    database_yml = source_database_yml_for_news_items_sync(source_app_root)

    raw = ERB.new(File.read(database_yml)).result
    parsed = YAML.safe_load(raw, aliases: true) || {}
    env_key = Rails.env
    env_cfg = parsed[env_key]
    raise "No database config found for env=#{env_key} in #{database_yml}" if env_cfg.blank?

    primary_cfg = env_cfg['primary'] || env_cfg[:primary] || env_cfg
    raise "No primary database config found for env=#{env_key} in #{database_yml}" if primary_cfg.blank?

    primary_cfg.deep_symbolize_keys
  end

  def reset_pk_sequence_for_news_items_sync!(table_name)
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

  desc 'Sync news items from another ASAP instance (dev -> production)'
  task :sync_from_dev, [:source_app_root] => :environment do |_task, args|
    source_app_root = Pathname.new(args[:source_app_root].presence || source_app_root_for_news_items_sync.to_s)
    dry_run = ENV['DRY_RUN'] == '1'

    source_config = source_db_config_for_news_items_sync!(source_app_root)
    SyncSourceBase.establish_connection(source_config)

    source_items = SyncSourceNewsItem.order(:id).map do |item|
      attrs = item.attributes
      {
        id: attrs['id'],
        title: attrs['title'],
        body: attrs['body'],
        news_type: attrs['news_type'],
        icon: attrs['icon'],
        published_at: attrs['published_at'],
        published: attrs.key?('published') ? attrs['published'] : true,
        show_on_welcome: attrs.key?('show_on_welcome') ? attrs['show_on_welcome'] : true,
        github_discussion_node_id: attrs['github_discussion_node_id'],
        github_discussion_url: attrs['github_discussion_url'],
        github_discussion_number: attrs['github_discussion_number'],
        github_synced_at: attrs['github_synced_at'],
        # Authors differ across environments; avoid FK failures on production users.
        user_id: nil,
        created_at: attrs['created_at'],
        updated_at: attrs['updated_at']
      }
    end

    puts "[news_items:sync_from_dev] source_app_root=#{source_app_root} source_items=#{source_items.size} dry_run=#{dry_run}"

    if dry_run
      source_items.each do |item|
        puts "  - id=#{item[:id]} type=#{item[:news_type]} published=#{item[:published]} welcome=#{item[:show_on_welcome]} title=#{item[:title].inspect}"
      end
      puts '[news_items:sync_from_dev] DRY_RUN enabled, no changes applied'
      next
    end

    ActiveRecord::Base.transaction do
      NewsItem.delete_all
      NewsItem.insert_all!(source_items) if source_items.any?
      reset_pk_sequence_for_news_items_sync!('news_items')
    end

    puts '[news_items:sync_from_dev] sync completed successfully'
  ensure
    SyncSourceBase.remove_connection
  end
end
