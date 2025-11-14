module VersionsHelper
  def format_version_release_date(version)
    return 'Unknown release date' unless version.release_date

    version.release_date.strftime('%B %d, %Y')
  end

  def tool_versions_from(env_hash)
    env_hash.fetch('tool_versions', {})
  rescue StandardError
    {}
  end

  def docker_images_from(env_hash)
    env_hash.fetch('docker_images', {})
  rescue StandardError
    {}
  end

  def docker_image_label(name, metadata, record = nil)
    tag = metadata.is_a?(Hash) ? metadata['tag'] : nil
    tag ||= record&.tag
    tag.present? ? "#{name} (#{tag})" : name
  end

  def docker_image_metadata_hash(metadata, record = nil)
    metadata_hash = metadata.is_a?(Hash) ? metadata : {}
    if metadata_hash.blank? && record&.metadata_json.present?
      metadata_hash = Basic.safe_parse_json(record.metadata_json, {})
    end
    metadata_hash || {}
  end

  def docker_image_tools(metadata_hash, record = nil)
    metadata_hash ||= {}
    tools = metadata_hash['tool_versions'] || metadata_hash['tool_versions_json']
    tools = Basic.safe_parse_json(tools, {}) if tools.is_a?(String)
    tools = tools.is_a?(Hash) ? tools : {}
    return tools if tools.present?

    return {} unless record

    raw = record.tool_versions_json.presence || record.tools_json
    Basic.safe_parse_json(raw, {})
  rescue StandardError
    {}
  end

  def grouped_tools_by_language(docker_version_tools, metadata_hash = {}, record: nil, &metadata_lookup)
    docker_version_tools ||= {}
    grouped = Hash.new { |hash, key| hash[key] = [] }
    metadata_hash ||= {}
    metadata_hash = docker_image_metadata_hash(metadata_hash, record)
    manual_groups = metadata_hash['tool_groups'] || metadata_hash['grouped_tools']

    docker_version_tools.each do |tool_name, version|
      tool_metadata = metadata_lookup&.call(tool_name) || {}
      package = tool_metadata[:package] || tool_metadata[:label] || tool_name
      url = tool_metadata[:url]
      language = tool_metadata[:language] || 'Other'

      if manual_groups.present?
        manual_groups.each do |group_name, list|
          next unless list.is_a?(Array)

          entry = list.find do |item|
            item_name = item.is_a?(Hash) ? (item['name'] || item['package'] || item['label']) : item
            item_name.to_s.casecmp?(tool_name.to_s)
          end
          next unless entry

          package = entry.is_a?(Hash) ? (entry['label'] || entry['package'] || entry['name'] || package) : entry
          url = entry.is_a?(Hash) ? entry['url'] : nil
          language = group_name
          break
        end
      end

      tool_id = tool_metadata[:id] || (tool_metadata[:tool] ? tool_metadata[:tool].id : nil)
      grouped[language] << { package:, version:, url:, tool_id: tool_id }
    end

    grouped.transform_values do |list|
      list.sort_by { |item| item[:package].to_s.downcase }
    end.sort.to_h
  end
end

