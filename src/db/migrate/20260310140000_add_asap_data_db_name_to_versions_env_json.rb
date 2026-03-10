class AddAsapDataDbNameToVersionsEnvJson < ActiveRecord::Migration[8.0]
  class VersionRecord < ActiveRecord::Base
    self.table_name = "versions"
  end

  def up
    VersionRecord.find_each do |version|
      env_data = Basic.safe_parse_json(version.env_json, {})
      db_version = env_data["asap_data_db_version"]
      next if db_version.blank?

      expected_db_name = "asap_data_v#{db_version}"
      next if env_data["asap_data_db_name"] == expected_db_name

      env_data["asap_data_db_name"] = expected_db_name
      version.update_columns(env_json: JSON.generate(env_data))
    end
  end

  def down
    VersionRecord.find_each do |version|
      env_data = Basic.safe_parse_json(version.env_json, {})
      next unless env_data.key?("asap_data_db_name")

      env_data.delete("asap_data_db_name")
      version.update_columns(env_json: JSON.generate(env_data))
    end
  end
end
