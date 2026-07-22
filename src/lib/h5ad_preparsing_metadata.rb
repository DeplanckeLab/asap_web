# frozen_string_literal: true

require 'json'
require 'open3'

# Discover AnnData var/obs columns for the new-project preparsing UI when ASAP.jar
# or preparse.v8.py do not populate output.json metadata (common for modern H5AD).
module H5adPreparsingMetadata
  H5AD_METADATA_DISCOVER_PY = (<<~'PYTHON').freeze
    import h5py
    import json
    import sys

    def is_string_dataset(ds):
        if h5py.check_string_dtype(ds.dtype):
            return True
        return ds.dtype.kind in ("O", "S", "U")

    def scan_group(grp, n, on):
        out = []
        if n <= 0:
            return out
        for name in grp.keys():
            if name.startswith("__"):
                continue
            item = grp[name]
            if isinstance(item, h5py.Dataset):
                if item.shape != (n,):
                    continue
                if is_string_dataset(item):
                    path = f"/var/{name}" if on == "GENE" else f"/obs/{name}"
                    out.append({"name": name, "path": path, "type": "STRING", "on": on})
            elif isinstance(item, h5py.Group) and "categories" in item and "codes" in item:
                codes = item["codes"]
                if codes.shape == (n,):
                    path = f"/var/{name}" if on == "GENE" else f"/obs/{name}"
                    out.append({"name": name, "path": path, "type": "STRING", "on": on})
        return out

    path = sys.argv[1]
    with h5py.File(path, "r") as f:
        if "X" not in f:
            print(json.dumps({"metadata": []}))
            sys.exit(0)
        shape = f["X"].attrs.get("shape", None)
        if shape is None:
            shape = f["X"].attrs.get("h5sparse_shape", None)
        if shape is None:
            shape = f["X"].shape
        n_cells = int(shape[0])
        n_genes = int(shape[1])
        meta = []
        if "var" in f and isinstance(f["var"], h5py.Group):
            meta.extend(scan_group(f["var"], n_genes, "GENE"))
        if "obs" in f and isinstance(f["obs"], h5py.Group):
            meta.extend(scan_group(f["obs"], n_cells, "CELL"))

        def pick_index_path(on, prefix):
            for name in ("_index", "index"):
                if any(e["on"] == on and e["name"] == name for e in meta):
                    return f"{prefix}/{name}"
            return None

        row_names = pick_index_path("GENE", "/var")
        col_names = pick_index_path("CELL", "/obs")
        print(json.dumps({"metadata": meta, "row_names": row_names, "col_names": col_names}))
  PYTHON

  module_function

  # Legacy Java Preparsing expects HDF5 paths (e.g. /var/_index), not AnnData column names.
  def java_metadata_path(value, axis)
    s = value.to_s.strip
    return nil if s.blank?

    return s if s.start_with?('/')

    prefix = axis == :row ? '/var/' : '/obs/'
    "#{prefix}#{s.delete_prefix('/')}"
  end

  def normalize_output_metadata_paths!(output)
    return output unless output.is_a?(Hash)
    return output unless output['detected_format'].to_s == 'H5AD'

    output['row_names'] = java_metadata_path(output['row_names'], :row) if output['row_names'].present?
    output['col_names'] = java_metadata_path(output['col_names'], :col) if output['col_names'].present?

    Array(output['metadata']).each do |entry|
      next unless entry.is_a?(Hash)

      on = entry['on'].to_s
      name = entry['name'].to_s
      next if name.blank?

      entry['path'] = java_metadata_path(entry['path'].presence || name, on == 'GENE' ? :row : :col)
    end

    Array(output['list_groups']).each do |group|
      next unless group.is_a?(Hash)

      Array(group['metadata']).each do |entry|
        next unless entry.is_a?(Hash)

        on = entry['on'].to_s
        name = entry['name'].to_s
        next if name.blank?

        entry['path'] = java_metadata_path(entry['path'].presence || name, on == 'GENE' ? :row : :col)
      end
    end

    output
  end

  def metadata_blank?(output)
    top = Array(output['metadata']).compact
    return false if top.any?

    Array(output['list_groups']).none? do |group|
      Array(group['metadata']).compact.any?
    end
  end

  def enrich_output!(output, host_path:, workdir:, logger: Rails.logger)
    return output unless output.is_a?(Hash)
    return output unless output['detected_format'].to_s == 'H5AD'
    return output unless metadata_blank?(output)
    return output unless host_path.present? && File.exist?(host_path.to_s)

    discovered = discover_metadata(host_path, workdir: workdir, logger: logger)
    return output if discovered.blank?

    meta = Array(discovered['metadata']).compact
    return output if meta.empty?

    output['metadata'] = meta
    output['row_names'] = discovered['row_names'] if discovered.key?('row_names')
    output['col_names'] = discovered['col_names'] if discovered.key?('col_names')

    Array(output['list_groups']).each do |group|
      group['metadata'] = meta if Array(group['metadata']).compact.empty?
    end

    normalize_output_metadata_paths!(output)
    logger.info("[H5adPreparsingMetadata] Enriched preparsing output with #{meta.size} metadata entries")
    output
  end

  def discover_metadata(host_path, workdir:, logger: Rails.logger)
    stdout, stderr, status = Open3.capture3(
      'docker', 'exec',
      '--user', '1006:1006',
      '--workdir', workdir.to_s,
      ENV.fetch('ASAP_RUN_CONTAINER'),
      'python3', '-c', H5AD_METADATA_DISCOVER_PY, host_path.to_s
    )
    unless status.success?
      logger.warn(
        "[H5adPreparsingMetadata] discovery failed (exit #{status.exitstatus}): #{stderr.to_s.strip.presence || stdout.to_s.strip}"
      )
      return nil
    end

    JSON.parse(stdout.to_s)
  rescue JSON::ParserError => e
    logger.warn("[H5adPreparsingMetadata] invalid discovery JSON: #{e.message}")
    nil
  end
end
