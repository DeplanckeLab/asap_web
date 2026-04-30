class Asap2RemoteRecord < ApplicationRecord
  self.abstract_class = true

  class << self
    def remote_versions
      remote_shards.keys.map(&:to_s)
    end

    def with_remote(version = default_remote_db, role: :writing)
      shard = normalized_shard(version)
      raise ArgumentError, "Unknown remote database #{version}" unless shard
      Asap2RemoteRecord.connected_to(role: role, shard: shard) { yield }
    end

    def connection_for(version = default_remote_db)
      shard = normalized_shard(version)
      raise ArgumentError, "Unknown remote database #{version}" unless shard
      Asap2RemoteRecord.connected_to(role: :writing, shard: shard) { connection }
    end

    private

    def remote_shards
      REMOTE_SHARDS
    end

    def default_remote_db
      normalize_db_name(ENV["ASAP2_REMOTE_DB"]) || remote_shards.keys.first
    end

    def normalized_shard(value)
      name = normalize_db_name(value)
      name if name && remote_shards.key?(name)
    end

    def normalize_db_name(value)
      return if value.nil?
      name = value.to_s.strip
      return if name.empty?
      return unless name.start_with?("asap_data_")

      normalized = name.to_sym
      normalized if remote_db_names.include?(normalized)
    end

    def remote_db_names
      REMOTE_DB_NAMES
    end
  end

  REMOTE_DB_NAMES = begin
    ENV.fetch("ASAP2_DATA_VERSIONS", "asap_data_v4,asap_data_v5,asap_data_v6,asap_data_v8")
      .split(",")
      .map { |name| name.to_s.strip }
      .reject(&:empty?)
      .select { |name| name.start_with?("asap_data_") }
      .map(&:to_sym)
      .uniq
  end.freeze

  REMOTE_SHARDS = REMOTE_DB_NAMES.index_with do |db_name|
    { writing: db_name, reading: db_name }
  end.freeze

  connects_to shards: REMOTE_SHARDS if REMOTE_SHARDS.present?
end

