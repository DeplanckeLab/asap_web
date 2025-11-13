module DockerImagesHelper
  def docker_image_tool_versions(docker_image)
    json_string = docker_image.tool_versions_json.presence || docker_image.tools_json
    Basic.safe_parse_json(json_string, {})
  rescue StandardError
    {}
  end

  def docker_image_metadata(docker_image)
    Basic.safe_parse_json(docker_image.metadata_json, {})
  rescue StandardError
    {}
  end
end

