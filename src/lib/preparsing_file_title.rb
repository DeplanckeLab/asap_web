# frozen_string_literal: true

require 'json'
require 'open3'

# Discover a human-readable dataset title from file-level attributes:
# - H5AD: /uns/title
# - LOOM: /attrs/title
module PreparsingFileTitle
  FILE_TITLE_DISCOVER_PY = (<<~'PYTHON').freeze
    import h5py
    import json
    import sys

    def decode_scalar(value):
        if value is None:
            return None
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace").strip() or None
        if isinstance(value, str):
            return value.strip() or None
        try:
            import numpy as np
            if isinstance(value, np.ndarray):
                if value.shape == ():
                    return decode_scalar(value.item())
                if value.size == 1:
                    return decode_scalar(value.reshape(-1)[0])
                return None
            if isinstance(value, (np.bytes_, np.str_)):
                return decode_scalar(value.item())
        except Exception:
            pass
        return None

    def read_title_from_group(grp, key="title"):
        if grp is None or key not in grp:
            return None
        item = grp[key]
        if isinstance(item, h5py.Dataset):
            if item.shape not in ((), (1,)):
                if len(item.shape) == 1 and item.shape[0] == 1:
                    return decode_scalar(item[0])
                return None
            return decode_scalar(item[()])
        return None

    def read_h5ad_title(f):
        if "uns" in f and isinstance(f["uns"], h5py.Group):
            title = read_title_from_group(f["uns"], "title")
            if title:
                return title
            if "title" in f["uns"].attrs:
                return decode_scalar(f["uns"].attrs["title"])
        return None

    def read_loom_title(f):
        if "attrs" in f and isinstance(f["attrs"], h5py.Group):
            title = read_title_from_group(f["attrs"], "title")
            if title:
                return title
            if "title" in f["attrs"].attrs:
                return decode_scalar(f["attrs"].attrs["title"])
        if "title" in f.attrs:
            return decode_scalar(f.attrs["title"])
        return None

    path = sys.argv[1]
    fmt = (sys.argv[2] if len(sys.argv) > 2 else "").upper()
    with h5py.File(path, "r") as f:
        title = None
        if fmt == "H5AD" or ("uns" in f and "X" in f):
            title = read_h5ad_title(f)
        if not title and (fmt == "LOOM" or "attrs" in f):
            title = read_loom_title(f)
        print(json.dumps({"title": title}))
  PYTHON

  module_function

  def enrich_output!(output, host_path:, workdir:, logger: Rails.logger)
    return output unless output.is_a?(Hash)

    fmt = output['detected_format'].to_s.upcase
    return output unless %w[H5AD LOOM].include?(fmt)
    return output if output['title'].to_s.strip.present?
    return output unless host_path.present? && File.exist?(host_path.to_s)

    discovered = discover_title(host_path, format: fmt, workdir: workdir, logger: logger)
    title = discovered.is_a?(Hash) ? discovered['title'].to_s.strip : ''
    return output if title.blank?

    output['title'] = title
    logger.info("[PreparsingFileTitle] Set preparsing title=#{title.inspect} for format=#{fmt}")
    output
  end

  def discover_title(host_path, format:, workdir:, logger: Rails.logger)
    stdout, stderr, status = Open3.capture3(
      'docker', 'exec',
      '--user', '1006:1006',
      '--workdir', workdir.to_s,
      ENV.fetch('ASAP_RUN_CONTAINER'),
      'python3', '-c', FILE_TITLE_DISCOVER_PY, host_path.to_s, format.to_s
    )
    unless status.success?
      logger.warn(
        "[PreparsingFileTitle] discovery failed (exit #{status.exitstatus}): #{stderr.to_s.strip.presence || stdout.to_s.strip}"
      )
      return nil
    end

    JSON.parse(stdout.to_s)
  rescue JSON::ParserError => e
    logger.warn("[PreparsingFileTitle] invalid discovery JSON: #{e.message}")
    nil
  end
end
