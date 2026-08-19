require 'open3'
require 'json'
require 'shellwords'
require 'securerandom'
require 'pathname'

class H5DataService
  ASAP_RUN_CONTAINER = ENV.fetch('ASAP_RUN_CONTAINER').freeze

  # Serialize writers for a loom. h5py "r+" takes an exclusive HDF5 lock; concurrent
  # opens raise BlockingIOError. Same pattern as Basic.ensure_markers_original_gene_attr.
  def self.with_loom_write_lock(loom_path)
    path = loom_path.to_s
    lock_path = "#{path}.asap_h5_lock"
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lockf|
      lockf.flock(File::LOCK_EX)
      yield
    end
  end

  def self.run_with_optional_loom_write_lock(loom_path, already_locked:)
    if already_locked
      yield
    else
      with_loom_write_lock(loom_path) { yield }
    end
  end

  # docker exec python for loom mutations. HDF5_USE_FILE_LOCKING=FALSE avoids
  # BlockingIOError when another client still holds an HDF5 advisory lock; writers
  # must still use with_loom_write_lock for mutual exclusion.
  def self.docker_exec_h5_write_python3!(*argv, stdin_data:)
    Open3.capture3(
      'docker', 'exec', '-i',
      '-e', 'HDF5_USE_FILE_LOCKING=FALSE',
      ASAP_RUN_CONTAINER, 'python3', '-',
      *argv,
      stdin_data: stdin_data
    )
  end

  # ASAP.jar ExtractDataset only accepts /matrix or /layers/* (JSON error otherwise).
  # /attrs/* DE tables are compound or non-float HDF5; read a small slice with h5py in the run container.
  H5_ATTRS_PREVIEW_PY = <<~PYTHON
    import json
    import sys

    import h5py

    def cell(v):
        if v is None:
            return None
        if hasattr(v, 'item'):
            try:
                v = v.item()
            except Exception:
                pass
        if isinstance(v, (bytes, bytearray)):
            return v.decode('utf-8', 'replace')
        if isinstance(v, (str, int, float, bool)):
            return v
        return str(v)

    def main():
        loom = sys.argv[1]
        path = sys.argv[2]
        max_r = int(sys.argv[3])
        max_c = int(sys.argv[4])
        with h5py.File(loom, 'r') as f:
            if path not in f:
                print(json.dumps({'error': 'not_found', 'path': path}))
                return 2
            d = f[path]
            if not hasattr(d, 'shape'):
                print(json.dumps({'error': 'not_a_dataset', 'path': path}))
                return 3
            sh = tuple(int(x) for x in d.shape)
            dt = d.dtype
            names = getattr(dt, 'names', None)
            take_r = min(max_r, sh[0]) if len(sh) >= 1 else 0
            if take_r <= 0:
                print(json.dumps({'rows': [], 'nber_rows': 0, 'nber_cols': 0, 'column_names': []}))
                return 0
            rows = []
            if len(sh) == 1 and names:
                block = d[:take_r]
                all_names = [str(n) for n in names]
                take_c_eff = min(max_c, len(all_names))
                use_names = all_names[:take_c_eff]
                for i in range(block.shape[0]):
                    rows.append([cell(block[i][n]) for n in use_names])
                out = {
                    'rows': rows,
                    'nber_rows': sh[0],
                    'nber_cols': len(all_names),
                    'column_names': use_names,
                }
            elif len(sh) >= 2:
                take_c = min(max_c, sh[1])
                block = d[:take_r, :take_c]
                for i in range(block.shape[0]):
                    rows.append([cell(block[i, j]) for j in range(block.shape[1])])
                out = {
                    'rows': rows,
                    'nber_rows': sh[0],
                    'nber_cols': sh[1],
                    'column_names': [str(j) for j in range(block.shape[1])],
                }
            elif len(sh) == 1:
                block = d[:take_r]
                for i in range(block.shape[0]):
                    rows.append([cell(block[i])])
                out = {'rows': rows, 'nber_rows': sh[0], 'nber_cols': 1, 'column_names': ['value']}
            else:
                print(json.dumps({'error': 'unsupported_rank', 'rank': len(sh)}))
                return 4
            print(json.dumps(out, default=str))
        return 0

    if __name__ == '__main__':
        sys.exit(main() or 0)
  PYTHON

  def self.asap_command(*args)
    ['docker', 'exec', ASAP_RUN_CONTAINER, 'java', '-jar', '/srv/ASAP.jar'] + args
  end

  def self.command_to_string(cmd_array)
    Shellwords.join(cmd_array)
  end

  # Full ExtractMetadata JSON (used when re-interpreting metadata type, e.g. annot update).
  # type_name: NUMERIC, CATEGORICAL, STRING, etc. as accepted by ASAP.jar -type
  def self.extract_metadata_compl(loom_path, meta_path, type_name:, no_values: true)
    args = ['-T', 'ExtractMetadata', '-loom', loom_path]
    args.push('-no-values') if no_values
    args.push('-type', type_name.to_s) if type_name.present?
    args.push('-meta', meta_path.to_s)
    cmd = asap_command(*args)
    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      Rails.logger.error("[H5DataService.extract_metadata_compl] failed: #{stderr}")
      return {}
    end
    JSON.parse(stdout)
  rescue JSON::ParserError => e
    Rails.logger.error("[H5DataService.extract_metadata_compl] parse error: #{e.message}")
    {}
  end

  # 1. Gene expression data
  def self.get_gene_data(genes, h5_path)
    sanitized_genes = genes.map(&:to_s)
    cmd = asap_command(
      '-T', 'ExtractRow',
      '-loom', h5_path,
      '-iAnnot', '/matrix',
      '-names', sanitized_genes.join(',')
    )

    stdout, stderr, status = Open3.capture3(*cmd)

    if status.success?
      begin
        JSON.parse(stdout)
      rescue JSON::ParserError => e
        Rails.logger.error("Failed to parse JSON from h5 query: #{e.message}")
        Rails.logger.error("Command output: #{stdout}")
        raise "Failed to parse h5 query results"
      end
    else
      Rails.logger.error("h5 query failed: #{stderr}")
      raise "Failed to query h5 file"
    end
  end

  # Extract one or more rows from a 2D loom dataset (e.g. /matrix, /attrs/...).
  # ASAP.jar ExtractRow requires exactly one of: -indexes, -names, -stable_ids (not -start/-nber).
  def self.extract_row_by_indexes(h5_file, i_annot, indexes)
    idx = Array(indexes).map(&:to_i).uniq
    raise ArgumentError, 'indexes required' if idx.empty?

    cmd = asap_command(
      '-T', 'ExtractRow',
      '-loom', h5_file,
      '-iAnnot', i_annot.to_s,
      '-indexes', idx.map(&:to_s).join(',')
    )
    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      raise "ASAP.jar ExtractRow failed for #{i_annot} (exit #{status.exitstatus}): #{stderr}"
    end

    parsed = JSON.parse(stdout)
    parsed['rows'] = parsed['values'] if parsed['rows'].blank? && parsed['values'].is_a?(Array)
    parsed
  end

  # 1b. Pathway expression data (same as genes but from pathway-specific loom file)
  def self.get_pathway_data(pathway_ids, h5_path, annot_name = '/matrix')
    # Use indexes (IDs) instead of names to avoid comma-separation issues
    # Convert pathway IDs to 0-based indexes (assuming IDs start from 1)
    indexes = pathway_ids.map { |id| (id.to_i - 1).to_s }
    cmd = asap_command(
      '-T', 'ExtractRow',
      '-loom', h5_path,
      '-iAnnot', annot_name,
      '-indexes', indexes.join(',')
    )

    stdout, stderr, status = Open3.capture3(*cmd)

    if status.success?
      begin
        JSON.parse(stdout)
      rescue JSON::ParserError => e
        raise "Failed to parse pathway h5 query results"
      end
    else
      raise "Failed to query pathway h5 file"
    end
  end

  # 2. UMAP coordinates (from JSON file)
  def self.get_umap_coordinates(umap_path)
    #raise "UMAP file not found: #{umap_path}" unless File.exist?(umap_path)
    #JSON.parse(File.read(umap_path))
    cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -meta /col_attrs/#{annot_name} -loom #{h5_path}"

    stdout, stderr, status = Open3.capture3(cmd)
  end

  # 3. Annotation categories (category => [cell_ids])
  def self.get_annotation_categories(h5_path, annot_name, dataset_metadata_path = nil)
    cmd = asap_command(
      '-T', 'ExtractMetadata',
      '-meta', "/col_attrs/#{annot_name}",
      '-loom', h5_path
    )

    stdout, stderr, status = Open3.capture3(*cmd)

    raise "Failed to extract annotation metadata: #{stderr}" unless status.success?

    begin
      meta = JSON.parse(stdout)
      values = meta['values']

      if values.include?('Unselected')
        unselected_count_original = values.count('Unselected')
      end

      # If dataset name is provided, check for dataset filtering
      if dataset_metadata_path and dataset_metadata_path.strip != "Integrated"
        dataset_cmd = asap_command(
          '-T', 'ExtractMetadata',
          '-meta', '/col_attrs/Condition',
          '-loom', h5_path
        )
        dataset_stdout, dataset_stderr, dataset_status = Open3.capture3(*dataset_cmd)

        if dataset_status.success?
          dataset_meta = JSON.parse(dataset_stdout)
          dataset_values = dataset_meta['values']

          # Count cells for each dataset
          dataset_counts = dataset_values.group_by(&:itself).transform_values(&:count)

          # Modify annotation values to "Unselected" when dataset doesn't match the specified name
          unselected_count = 0
          selected_count = 0
          values.each_with_index do |value, idx|
            if dataset_values[idx] != dataset_metadata_path
              values[idx] = "Unselected"
              unselected_count += 1
            else
              selected_count += 1
            end
          end
        else
          Rails.logger.warn("Failed to extract dataset metadata: #{dataset_stderr}")
          Rails.logger.warn("Dataset command status: #{dataset_status}")
        end
      else
        Rails.logger.debug("Dataset filtering disabled - dataset_metadata_path: #{dataset_metadata_path}")
        Rails.logger.debug("No filtering applied - using original annotation values")
      end

      cell_ids = (0...values.length).to_a
      categories = values.uniq

      result = {}
      categories.each { |cat| result[cat] = [] }
      values.each_with_index { |cat, idx| result[cat] << cell_ids[idx] }

      # Log summary of final categories
      total_cells = result.values.sum(&:length)

      result
    rescue JSON::ParserError => e
      Rails.logger.error("JSON parse error: #{e.message}")
      Rails.logger.error("STDOUT content: #{stdout}")
      raise "Failed to parse annotation metadata JSON: #{e.message}"
    end
  end



  def self.get_metadata_values(h5_file, metadata_path)
    begin
      # Use ASAP.jar to extract metadata values with -no-values flag for clean summary
      cmd = asap_command(
        '-T', 'ExtractMetadata',
        '-no-values',
        '-meta', metadata_path,
        '-loom', h5_file
      )
      stdout, stderr, status = Open3.capture3(*cmd)

      if status.success?
        # Parse the JSON output to extract unique category names
        begin
          json_data = JSON.parse(stdout)
          categories = json_data['categories']
          if categories
            # Return just the category names (keys) as an array
            categories.keys.sort
          else
            Rails.logger.error "No categories found in metadata output: #{stdout}"
            []
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Failed to parse JSON from metadata extraction: #{e.message}"
          Rails.logger.error "Raw output: #{stdout}"
          []
        end
      else
        Rails.logger.error "Failed to extract metadata from #{metadata_path}: #{stderr}"
        []
      end
    rescue => e
      Rails.logger.error "Error extracting metadata from #{metadata_path}: #{e.message}"
      []
    end
  end

  # DE and other /attrs/ tables: compound HDF5 (ExtractRow float path fails). ASAP.jar ExtractDataset
  # rejects paths outside /matrix and /layers/*. Read a bounded slice via h5py in ASAP_RUN_CONTAINER.
  def self.get_attrs_matrix_sample_for_preview(h5_file, annot_path, max_preview_rows: 10, max_preview_cols: 10, total_rows: nil, total_cols: nil)
    internal = annot_path.to_s.sub(%r{\A/+}, '')

    tr = max_preview_rows
    tr = [max_preview_rows, total_rows.to_i].min if total_rows.to_i.positive?
    tr = 1 if tr < 1

    tc = max_preview_cols
    tc = [max_preview_cols, total_cols.to_i].min if total_cols.to_i.positive?
    tc = 1 if tc < 1

    stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
      h5_file, internal, tr.to_s, tc.to_s,
      stdin_data: H5_ATTRS_PREVIEW_PY
    )

    parsed =
      begin
        JSON.parse(stdout.to_s.strip)
      rescue JSON::ParserError => e
        hint = [stdout, stderr].map { |s| s.to_s.strip[0, 500] }.reject(&:empty?).join(' | ')
        raise "attrs preview: invalid JSON (#{e.message}). #{hint}"
      end

    if parsed['error']
      raise "attrs preview (#{annot_path}): #{parsed['error']} (#{parsed.inspect})"
    end

    unless status.success?
      msg = stderr.to_s.strip
      msg = stdout.to_s.strip[0, 500] if msg.empty?
      raise "attrs preview docker/python failed (exit #{status.exitstatus}): #{msg}"
    end

    all_rows = parsed['rows']
    unless all_rows.is_a?(Array) && all_rows.any?
      raise "attrs preview returned no rows for #{annot_path}"
    end

    sample_rows = all_rows.map { |r| r.is_a?(Array) ? r : [r] }

    nr = parsed['nber_rows'].to_i
    nr = total_rows.to_i if nr <= 0 && total_rows.to_i.positive?
    nr = sample_rows.size if nr <= 0

    # Full column count from the file (compound dtype or matrix width), not only the preview slice.
    nc_full = parsed['nber_cols'].to_i
    nc_full = sample_rows.first.size if nc_full <= 0 && sample_rows.first.is_a?(Array)
    if total_cols.to_i.positive? && nc_full.positive? && total_cols.to_i != nc_full
      Rails.logger.warn(
        "[H5DataService.get_attrs_matrix_sample_for_preview] #{annot_path}: Annot nber_cols=#{total_cols} " \
        "does not match HDF5 column count #{nc_full}"
      )
    end

    cn = parsed['column_names']
    cn = nil unless cn.is_a?(Array) && cn.any?

    {
      nber_rows: nr,
      nber_cols: nc_full,
      values: sample_rows,
      column_names: cn
    }
  end

  # Full /attrs/ matrix (all genes x all columns) for DE filter output. Java ExtractMetadata often does not
  # return nested "values" for compound /attrs datasets; this uses the same h5py path as the preview reader.
  def self.get_attrs_matrix_full_for_de_filter(h5_file, annot_path, annot)
    internal = annot_path.to_s.sub(%r{\A/+}, '')

    max_r = annot.nber_rows.to_i
    max_r = 50_000_000 if max_r <= 0
    max_r = [[max_r, 50_000_000].min, 1].max

    max_c = annot.nber_cols.to_i
    max_c = 2048 if max_c <= 0
    max_c = [[max_c, 4096].min, 1].max

    stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
      h5_file.to_s, internal, max_r.to_s, max_c.to_s,
      stdin_data: H5_ATTRS_PREVIEW_PY
    )

    parsed =
      begin
        JSON.parse(stdout.to_s.strip)
      rescue JSON::ParserError => e
        hint = [stdout, stderr].map { |s| s.to_s.strip[0, 500] }.reject(&:empty?).join(' | ')
        raise "attrs full matrix: invalid JSON (#{e.message}). #{hint}"
      end

    if parsed['error']
      raise "attrs full matrix (#{annot_path}): #{parsed['error']} (#{parsed.inspect})"
    end

    unless status.success?
      msg = stderr.to_s.strip
      msg = stdout.to_s.strip[0, 500] if msg.empty?
      raise "attrs full matrix docker/python failed (exit #{status.exitstatus}): #{msg}"
    end

    all_rows = parsed['rows']
    unless all_rows.is_a?(Array) && all_rows.any?
      raise "attrs full matrix returned no rows for #{annot_path}"
    end

    rows = all_rows.map { |r| r.is_a?(Array) ? r : [r] }

    nr = parsed['nber_rows'].to_i
    nr = rows.size if nr <= 0

    nc_full = parsed['nber_cols'].to_i
    nc_full = rows.first.size if nc_full <= 0 && rows.first.is_a?(Array)

    cn = parsed['column_names']
    cn = nil unless cn.is_a?(Array) && cn.any?

    {
      'values' => rows,
      'nber_rows' => nr,
      'nber_cols' => nc_full,
      'column_names' => cn
    }
  end

  # Extract the full metadata vector for all cells (one value per cell)
  # Extract a 2D metadata matrix (e.g. /col_attrs/X_pca with shape (n_components, n_cells)).
  # Returns a hash: { nber_rows:, nber_cols:, values: Array<Array> }.
  # Raises on failure.
  def self.get_metadata_matrix(h5_file, metadata_path)
    cmd = asap_command(
      '-T', 'ExtractMetadata',
      '-meta', metadata_path,
      '-loom', h5_file
    )
    stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success?
      raise "ASAP.jar ExtractMetadata failed for #{metadata_path} (exit #{status.exitstatus}): #{stderr}"
    end

    json_data = JSON.parse(stdout)
    values = json_data['values']
    unless values.is_a?(Array) && values.first.is_a?(Array)
      raise "Metadata #{metadata_path} is not a 2D matrix (values shape is #{values&.class})"
    end

    {
      nber_rows: json_data['nber_rows'].to_i,
      nber_cols: json_data['nber_cols'].to_i,
      values: values
    }
  end

  def self.get_metadata_vector(h5_file, metadata_path)
    error_details = {}
    begin
      # Use ASAP.jar to extract the full metadata vector (with values)
      cmd = asap_command(
        '-T', 'ExtractMetadata',
        '-meta', metadata_path,
        '-loom', h5_file
      )
      Rails.logger.info "Executing ASAP.jar command: #{command_to_string(cmd)}"
      file_exists = File.exist?(h5_file)
      Rails.logger.info "File exists? #{file_exists}"
      error_details[:file_exists] = file_exists
      error_details[:file_path] = h5_file
      
      # Use Open3.capture3 to properly capture stdout and stderr
      stdout, stderr, status = Open3.capture3(*cmd)
      result = stdout
      
      Rails.logger.info "Command exit status: #{status.exitstatus}"
      Rails.logger.info "Command output length: #{result.length} characters"
      Rails.logger.info "Command stderr: #{stderr}" if stderr && !stderr.empty?
      
      error_details[:exit_status] = status.exitstatus
      error_details[:stdout_length] = result.length
      error_details[:stderr] = stderr if stderr && !stderr.empty?

      if status.success?
        begin
          # Parse JSON - handle both single vectors and coordinate pairs
          json_data = JSON.parse(result)
          
          Rails.logger.info "Metadata extraction result for #{metadata_path}: nber_rows=#{json_data['nber_rows']}, values type=#{json_data['values']&.class}"
          
          if json_data['values'].is_a?(Array)
            case json_data['nber_rows']
            when 2
              # Coordinate pairs - extract two vectors and zip them
              v1, v2 = json_data['values']
              if v1.is_a?(Array) && v2.is_a?(Array) && v1.length == v2.length
                # Convert to coordinate pairs
                coordinates = v1.zip(v2)
                Rails.logger.info "Successfully extracted metadata vector with #{coordinates.length} coordinate pairs from #{metadata_path}"
                return coordinates
              else
                Rails.logger.error "Invalid vector format for coordinate pairs: v1.length=#{v1&.length}, v2.length=#{v2&.length}"
                Rails.logger.error "v1 type: #{v1&.class}, v2 type: #{v2&.class}"
                return []
              end
            when 1
              # Single vector - return as array of single values
              # Handle case where values might be nested in another array
              single_vector = json_data['values']
              if single_vector.is_a?(Array)
                # Check if it's nested: [[values]] vs [values]
                if single_vector.length == 1 && single_vector[0].is_a?(Array)
                  Rails.logger.info "Detected nested array format, unwrapping"
                  single_vector = single_vector[0]
                end
                Rails.logger.info "Successfully extracted metadata vector with #{single_vector.length} single values from #{metadata_path}"
                return single_vector
              else
                Rails.logger.error "Invalid single vector format: type=#{single_vector.class}"
                return []
              end
            else
              nber_rows = json_data['nber_rows']
              nber_cols = json_data['nber_cols'] || 0
              
              # Handle case where nber_rows equals the number of genes (row metadata)
              # For row attributes like _StableID, nber_rows is the number of rows (genes)
              # and values should be a flat array with one value per row
              if json_data['values'].is_a?(Array)
                if nber_rows > 2 && nber_cols == 1
                  # This is row metadata: nber_rows = number of genes, nber_cols = 1 (one value per gene)
                  # Values should be a flat array: [val1, val2, val3, ...]
                  Rails.logger.info "Detected row metadata format: nber_rows=#{nber_rows} (genes), nber_cols=#{nber_cols}"
                  
                  # Check if values is nested or flat
                  if json_data['values'].length == 1 && json_data['values'][0].is_a?(Array)
                    # Nested: [[val1, val2, ...]]
                    single_vector = json_data['values'][0]
                    Rails.logger.info "Unwrapping nested array, extracted #{single_vector.length} values"
                    return single_vector
                  elsif json_data['values'].all? { |v| !v.is_a?(Array) }
                    # Flat array: [val1, val2, ...]
                    Rails.logger.info "Using flat array directly, extracted #{json_data['values'].length} values"
                    return json_data['values']
                  else
                    # Mixed or unexpected format
                    Rails.logger.warn "Unexpected mixed format in values array"
                    # Try to flatten it
                    flattened = json_data['values'].flatten
                    Rails.logger.info "Flattened array, extracted #{flattened.length} values"
                    return flattened
                  end
                else
                  # Unknown format, log and try to handle
                  Rails.logger.warn "Unexpected nber_rows value: #{nber_rows}, nber_cols: #{nber_cols}"
                  Rails.logger.warn "Values array length: #{json_data['values'].length}"
                  Rails.logger.warn "First value type: #{json_data['values'][0]&.class}"
                  
                  # Try to extract a flat vector if possible
                  if json_data['values'].all? { |v| !v.is_a?(Array) }
                    Rails.logger.warn "All values are non-array, using directly"
                    return json_data['values']
                  elsif json_data['values'].length == 1 && json_data['values'][0].is_a?(Array)
                    Rails.logger.warn "Single nested array, unwrapping"
                    return json_data['values'][0]
                  end
                end
              end
              
              error_msg = "Unexpected nber_rows value: #{nber_rows} (expected 1 or 2, or row metadata format)"
              Rails.logger.error error_msg
              Rails.logger.error "JSON structure: #{json_data.keys}" if json_data.is_a?(Hash)
              Rails.logger.error "nber_cols: #{nber_cols}"
              Rails.logger.error "Values length: #{json_data['values']&.length}"
              Rails.logger.error "Values first element type: #{json_data['values']&.first&.class}"
              raise "Metadata extraction failed: #{error_msg}. JSON keys: #{json_data.keys.inspect}. Check Rails logs for full details."
            end
          else
            error_msg = "Invalid JSON format: 'values' is not an array"
            Rails.logger.error error_msg
            Rails.logger.error "JSON structure: #{json_data.keys}" if json_data.is_a?(Hash)
            Rails.logger.error "values type: #{json_data['values']&.class}"
            Rails.logger.error "Raw output: #{result[0..500]}..." # Show first 500 chars
            raise "Metadata extraction failed: #{error_msg}. Check Rails logs for full details."
          end
        rescue JSON::ParserError => e
          error_msg = "Failed to parse JSON from metadata vector extraction: #{e.message}"
          Rails.logger.error error_msg
          Rails.logger.error "Raw output: #{result[0..1000]}" # First 1000 chars
          raise "Metadata extraction failed: #{error_msg}. Raw output preview: #{result[0..200]}. Check Rails logs for full details."
        end
      else
        error_msg = "ASAP.jar command failed (exit status: #{status.exitstatus})"
        Rails.logger.error error_msg
        Rails.logger.error "Command: #{command_to_string(cmd)}"
        Rails.logger.error "STDOUT: #{stdout[0..500]}" # First 500 chars
        Rails.logger.error "STDERR: #{stderr}" if stderr && !stderr.empty?
        Rails.logger.error "File path: #{h5_file}, exists: #{File.exist?(h5_file)}"
        error_details[:error] = error_msg
        error_details[:stdout_preview] = stdout[0..500] if stdout
        raise "Metadata extraction failed: #{error_msg}. STDERR: #{stderr}. Check Rails logs for full details."
      end
    rescue => e
      Rails.logger.error "Error extracting metadata vector from #{metadata_path}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise e
    end
  end

  # Read multiple 1-D loom metadata vectors in one h5py pass.
  # Returns { "/row_attrs/Gene" => [...], ... }. Missing paths are omitted (not nil).
  def self.get_metadata_vectors(h5_file, metadata_paths)
    paths = Array(metadata_paths).map(&:to_s).map { |p| p.start_with?('/') ? p : "/#{p}" }.uniq
    return {} if paths.empty?

    loom_path = Pathname.new(h5_file.to_s)
    raise "Loom file not found: #{loom_path}" unless File.exist?(loom_path)

    script = <<~PYTHON
      import h5py
      import json
      import sys
      import numpy as np

      def decode(value):
          if value is None:
              return ""
          if isinstance(value, (bytes, np.bytes_)):
              return value.decode("utf-8", "replace")
          return str(value)

      def read_vec(f, path):
          name = path[1:] if path.startswith("/") else path
          if name not in f:
              return None
          node = f[name]
          if not isinstance(node, h5py.Dataset):
              return None
          raw = node[()]
          if isinstance(raw, np.ndarray):
              items = raw.ravel().tolist()
          elif isinstance(raw, (list, tuple)):
              items = list(raw)
          else:
              items = [raw]
          return [decode(v) for v in items]

      paths = json.loads(sys.argv[2])
      out = {}
      with h5py.File(sys.argv[1], "r") as f:
          for path in paths:
              values = read_vec(f, path)
              if values is not None:
                  out[path if path.startswith("/") else "/" + path] = values
      print(json.dumps(out))
    PYTHON

    stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
      loom_path.to_s, paths.to_json,
      stdin_data: script
    )
    unless status.success?
      Rails.logger.error("[H5DataService] get_metadata_vectors failed: #{stderr.presence || stdout}")
      raise "Metadata extraction failed for #{paths.join(', ')}: #{stderr.presence || stdout}"
    end

    JSON.parse(stdout)
  rescue JSON::ParserError => e
    raise "Metadata extraction failed: invalid JSON (#{e.message})"
  end

  # Compare pairs of 1-D string metadata vectors in one h5py pass.
  # +pairs+ is an Array of hashes with :a/:b (or "a"/"b") paths (with or without leading slash).
  # Returns an Array of { "a" => path, "b" => path, "equal" => true/false/nil, "missing" => bool }.
  # equal is nil when either path is missing or not a readable dataset.
  def self.compare_metadata_vector_pairs(h5_file, pairs)
    normalized = Array(pairs).filter_map do |pair|
      next unless pair.is_a?(Hash)

      a = (pair[:a] || pair['a']).to_s
      b = (pair[:b] || pair['b']).to_s
      next if a.blank? || b.blank?

      { 'a' => strip_leading_slash(a), 'b' => strip_leading_slash(b) }
    end
    return [] if normalized.empty?

    script = <<~PYTHON
      import h5py
      import json
      import sys
      import numpy as np

      def decode(value):
          if value is None:
              return ""
          if isinstance(value, bytes):
              return value.decode("utf-8", "replace")
          return str(value)

      def read_vec(f, path):
          if path not in f:
              return None
          node = f[path]
          if not isinstance(node, h5py.Dataset):
              return None
          raw = node[()]
          if isinstance(raw, np.ndarray):
              items = raw.tolist()
          elif isinstance(raw, (list, tuple)):
              items = list(raw)
          else:
              items = [raw]
          return [decode(v) for v in items]

      pairs = json.loads(sys.argv[2])
      results = []
      with h5py.File(sys.argv[1], "r") as f:
          for pair in pairs:
              a_path = pair["a"]
              b_path = pair["b"]
              a = read_vec(f, a_path)
              b = read_vec(f, b_path)
              if a is None or b is None:
                  results.append({"a": a_path, "b": b_path, "equal": None, "missing": True})
              else:
                  results.append({"a": a_path, "b": b_path, "equal": a == b, "missing": False})
      print(json.dumps(results))
    PYTHON

    stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
      h5_file.to_s, normalized.to_json,
      stdin_data: script
    )
    unless status.success?
      Rails.logger.error("[H5DataService] compare_metadata_vector_pairs failed: #{stderr.presence || stdout}")
      raise "Failed to compare metadata vector pairs: #{stderr.presence || stdout}"
    end

    JSON.parse(stdout)
  end

  # True when +metadata_path+ (with or without leading slash) exists as an HDF5 dataset.
  def self.metadata_dataset_exists?(h5_file, metadata_path)
    field = strip_leading_slash(metadata_path)
    script = <<~PYTHON
      import h5py
      import sys

      with h5py.File(sys.argv[1], 'r') as f:
          print('EXISTS' if sys.argv[2] in f else 'NOT_FOUND')
    PYTHON
    stdout, stderr, status = Open3.capture3(
      'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-', h5_file.to_s, field,
      stdin_data: script
    )
    unless status.success?
      Rails.logger.error("[H5DataService] metadata_dataset_exists? failed: #{stderr}")
      return false
    end

    stdout.strip == 'EXISTS'
  end

  # Copy an existing metadata dataset to a new path. Fails if source is missing or target exists.
  def self.copy_metadata_dataset!(h5_file, source_path, target_path, already_locked: false)
    source = strip_leading_slash(source_path)
    target = strip_leading_slash(target_path)
    script = <<~PYTHON
      import h5py
      import sys

      loom_path = sys.argv[1]
      source = sys.argv[2]
      target = sys.argv[3]

      with h5py.File(loom_path, 'r+') as f:
          if source not in f:
              print('ERROR: Source path not found: ' + source)
              sys.exit(1)
          if target in f:
              print('ERROR: Target path already exists: ' + target)
              sys.exit(1)
          f[target] = f[source][:]

      print('OK')
    PYTHON
    run_with_optional_loom_write_lock(h5_file, already_locked: already_locked) do
      stdout, stderr, status = docker_exec_h5_write_python3!(
        h5_file.to_s, source, target,
        stdin_data: script
      )
      unless status.success? && stdout.strip.start_with?('OK')
        raise "Failed to copy metadata #{source_path} -> #{target_path}: #{stderr.presence || stdout}"
      end
    end

    true
  end

  # Delete a metadata dataset if present. No-op when missing.
  def self.delete_metadata_dataset!(h5_file, metadata_path, already_locked: false)
    delete_metadata_datasets!(h5_file, [metadata_path], already_locked: already_locked)
  end

  # Delete several metadata datasets in one h5py open. Missing paths are skipped.
  def self.delete_metadata_datasets!(h5_file, metadata_paths, already_locked: false)
    fields = Array(metadata_paths).map { |path| strip_leading_slash(path) }.reject(&:blank?).uniq
    return true if fields.empty?

    loom_path = Pathname.new(h5_file.to_s)
    staging_path = loom_path.dirname.join(".asap_delete_metadata_#{Process.pid}_#{SecureRandom.hex(8)}.json")
    File.write(staging_path, fields.to_json)

    script = <<~PYTHON
      import json
      import sys

      import h5py

      loom_path = sys.argv[1]
      paths_file = sys.argv[2]
      with open(paths_file, 'r', encoding='utf-8') as fh:
          fields = json.load(fh)
      if not isinstance(fields, list):
          print('ERROR: metadata path list must be a JSON array')
          sys.exit(1)

      with h5py.File(loom_path, 'r+') as f:
          for field in fields:
              if not isinstance(field, str) or field == '':
                  print('ERROR: metadata path must be a non-empty string')
                  sys.exit(1)
              if field in f:
                  del f[field]

      print('OK')
    PYTHON

    begin
      run_with_optional_loom_write_lock(h5_file, already_locked: already_locked) do
        stdout, stderr, status = docker_exec_h5_write_python3!(
          loom_path.to_s, staging_path.to_s,
          stdin_data: script
        )
        unless status.success? && stdout.strip.start_with?('OK')
          raise "Failed to delete metadata #{fields.join(', ')}: #{stderr.presence || stdout}"
        end
      end
      true
    ensure
      File.delete(staging_path) if File.exist?(staging_path)
    end
  end

  # Write a global loom attribute as a length-1 string dataset under attrs/<name>.
  # Also sets f.attrs[name] (loom-style file attribute). Replaces existing values.
  # The string is staged to a temp file under the loom directory (shared with the run container).
  def self.write_global_attr_string!(h5_file, metadata_path, value, already_locked: false)
    attr_name = strip_leading_slash(metadata_path).sub(%r{\Aattrs/}, '')
    raise ArgumentError, 'Global attr name is required' if attr_name.blank?

    loom_path = Pathname.new(h5_file.to_s)
    staging_path = loom_path.dirname.join(".asap_global_attr_write_#{Process.pid}_#{SecureRandom.hex(8)}.txt")
    File.write(staging_path, value.to_s)

    script = <<~PYTHON
      import h5py
      import numpy as np
      import sys

      loom_path = sys.argv[1]
      attr_name = sys.argv[2]
      value_path = sys.argv[3]
      with open(value_path, 'r', encoding='utf-8') as fh:
          value = fh.read()
      arr = np.array([value], dtype=h5py.special_dtype(vlen=str))
      attrs_path = 'attrs/' + attr_name

      with h5py.File(loom_path, 'r+') as f:
          f.attrs[attr_name] = value
          if attrs_path in f:
              del f[attrs_path]
          f.create_dataset(attrs_path, data=arr)

      print('OK')
    PYTHON

    begin
      run_with_optional_loom_write_lock(loom_path, already_locked: already_locked) do
        stdout, stderr, status = docker_exec_h5_write_python3!(
          loom_path.to_s, attr_name, staging_path.to_s,
          stdin_data: script
        )
        unless status.success? && stdout.strip.start_with?('OK')
          raise "Failed to write global attr #{metadata_path}: #{stderr.presence || stdout}"
        end
      end
      true
    ensure
      File.delete(staging_path) if File.exist?(staging_path)
    end
  end

  # Read a global loom attribute stored as attrs/<name> (length-1 string dataset) or f.attrs[name].
  # Prefer this over ASAP.jar ExtractMetadata for JSON payloads that break the Java JSON wrapper.
  def self.read_global_attr_string(h5_file, metadata_path)
    attr_name = strip_leading_slash(metadata_path).sub(%r{\Aattrs/}, '')
    raise ArgumentError, 'Global attr name is required' if attr_name.blank?

    loom_path = Pathname.new(h5_file.to_s)
    out_path = loom_path.dirname.join(".asap_global_attr_read_#{Process.pid}_#{SecureRandom.hex(8)}.txt")

    script = <<~PYTHON
      import h5py
      import sys

      loom_path = sys.argv[1]
      attr_name = sys.argv[2]
      out_path = sys.argv[3]
      attrs_path = 'attrs/' + attr_name
      value = None

      with h5py.File(loom_path, 'r') as f:
          if attrs_path in f:
              ds = f[attrs_path]
              if getattr(ds, 'shape', ()) == ():
                  value = ds[()]
              elif len(ds.shape) == 1 and ds.shape[0] >= 1:
                  value = ds[0]
              else:
                  value = ds[()]
          elif attr_name in f.attrs:
              value = f.attrs[attr_name]

      if value is None:
          print('MISSING')
          sys.exit(1)
      if isinstance(value, bytes):
          value = value.decode('utf-8')
      else:
          value = str(value)
      with open(out_path, 'w', encoding='utf-8') as fh:
          fh.write(value)
      print('OK')
    PYTHON

    begin
      stdout, stderr, status = Open3.capture3(
        'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
        loom_path.to_s, attr_name, out_path.to_s,
        stdin_data: script
      )
      unless status.success? && stdout.strip.start_with?('OK')
        raise "Failed to read global attr #{metadata_path}: #{stderr.presence || stdout}"
      end
      File.read(out_path, encoding: 'utf-8')
    ensure
      File.delete(out_path) if File.exist?(out_path)
    end
  end

  # Batch-read length-1 /attrs/* strings for data-view cards.
  # Returns { "/attrs/name" => "value" } for plain (non-JSON) strings with length <= max_chars.
  # Skips missing attrs, JSON object/array payloads, and longer values.
  def self.read_short_global_attr_strings(h5_file, metadata_paths, max_chars: 200)
    paths = Array(metadata_paths).map(&:to_s).uniq.select { |p| p.start_with?('/attrs/') || p.start_with?('attrs/') }
    return {} if paths.empty?

    loom_path = Pathname.new(h5_file.to_s)
    return {} unless File.exist?(loom_path)

    names_path = loom_path.dirname.join(".asap_global_attrs_names_#{Process.pid}_#{SecureRandom.hex(8)}.json")
    out_path = loom_path.dirname.join(".asap_global_attrs_read_#{Process.pid}_#{SecureRandom.hex(8)}.json")
    File.write(names_path, paths.to_json)

    script = <<~PYTHON
      import h5py
      import json
      import sys

      loom_path = sys.argv[1]
      names_path = sys.argv[2]
      out_path = sys.argv[3]
      max_chars = int(sys.argv[4])

      with open(names_path, 'r', encoding='utf-8') as fh:
          paths = json.load(fh)

      result = {}
      with h5py.File(loom_path, 'r') as f:
          for path in paths:
              name = path[1:] if path.startswith('/') else path
              if name.startswith('attrs/'):
                  attr_name = name[len('attrs/'):]
              else:
                  attr_name = name
              attrs_path = 'attrs/' + attr_name
              value = None
              if attrs_path in f:
                  ds = f[attrs_path]
                  if getattr(ds, 'shape', ()) == ():
                      value = ds[()]
                  elif len(ds.shape) == 1 and ds.shape[0] >= 1:
                      value = ds[0]
                  else:
                      continue
              elif attr_name in f.attrs:
                  value = f.attrs[attr_name]
              else:
                  continue
              if isinstance(value, bytes):
                  value = value.decode('utf-8')
              else:
                  value = str(value)
              s = value.strip()
              if len(s) == 0 or len(s) > max_chars:
                  continue
              if s.startswith('{') or s.startswith('['):
                  try:
                      parsed = json.loads(s)
                  except Exception:
                      parsed = None
                  if isinstance(parsed, (dict, list)):
                      continue
              key = path if path.startswith('/') else '/' + path
              result[key] = value

      with open(out_path, 'w', encoding='utf-8') as fh:
          json.dump(result, fh)
      print('OK')
    PYTHON

    begin
      stdout, stderr, status = Open3.capture3(
        'docker', 'exec', '-i', ASAP_RUN_CONTAINER, 'python3', '-',
        loom_path.to_s, names_path.to_s, out_path.to_s, max_chars.to_i.to_s,
        stdin_data: script
      )
      unless status.success? && stdout.strip.start_with?('OK')
        Rails.logger.error("Failed to batch-read global attrs: #{stderr.presence || stdout}")
        return {}
      end
      raw = File.read(out_path, encoding: 'utf-8')
      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError => e
      Rails.logger.error("Failed to batch-read global attrs: #{e.class}: #{e.message}")
      {}
    ensure
      File.delete(names_path) if File.exist?(names_path)
      File.delete(out_path) if File.exist?(out_path)
    end
  end

  # Write a 0/1 int32 cell-selection column. selected_indices_file is JSON:
  # {"selected_indices":[...]} with 0-based column indexes. Replaces the dataset
  # if it already exists (failed Java writes can leave the path without an annot).
  # Metadata JSON is written to a sidecar file so HDF5/JVM stdout cannot swallow it.
  def self.write_cell_selection!(h5_file, metadata_path, selected_indices_file, already_locked: false)
    field = strip_leading_slash(metadata_path)
    raise ArgumentError, 'Selection metadata path is required' if field.blank?

    loom_path = Pathname.new(h5_file.to_s)
    selected_path = Pathname.new(selected_indices_file.to_s)
    raise ArgumentError, 'Selection indices file not found' unless selected_path.file?

    out_path = selected_path.dirname.join(".asap_cell_selection_meta_#{Process.pid}_#{SecureRandom.hex(8)}.json")
    script = <<~PYTHON
      import json
      import sys

      import h5py
      import numpy as np

      loom_path = sys.argv[1]
      field = sys.argv[2]
      selected_path = sys.argv[3]
      out_path = sys.argv[4]

      def fail(message):
          with open(out_path, 'w', encoding='utf-8') as fh:
              json.dump({'displayed_error': message}, fh)
          print('ERROR')
          sys.exit(1)

      with open(selected_path, 'r', encoding='utf-8') as fh:
          payload = json.load(fh)
      if not isinstance(payload, dict):
          fail('Selection file must be a JSON object')
      raw_indices = payload.get('selected_indices')
      if not isinstance(raw_indices, list) or len(raw_indices) == 0:
          fail('selected_indices must be a non-empty list')

      with h5py.File(loom_path, 'r+') as f:
          if 'col_attrs/_StableID' not in f:
              fail('Loom is missing /col_attrs/_StableID')
          n_cells = int(f['col_attrs/_StableID'].shape[0])
          if n_cells <= 0:
              fail('Loom /col_attrs/_StableID is empty')
          mask = np.zeros(n_cells, dtype=np.int32)
          for raw in raw_indices:
              try:
                  idx = int(raw)
              except (TypeError, ValueError):
                  fail('selected_indices must contain integers')
              if idx < 0 or idx >= n_cells:
                  fail('Cell index ' + str(idx) + ' is out of range (n=' + str(n_cells) + ')')
              mask[idx] = 1
          n_selected = int(mask.sum())
          if n_selected == 0:
              fail('No valid selected cell indices')
          if field in f:
              del f[field]
          f.create_dataset(field, data=mask, dtype='int32')

      meta = {
          'name': '/' + field,
          'on': 'CELL',
          'type': 'DISCRETE',
          'nber_cols': n_cells,
          'nber_rows': 1,
          'categories': {
              '0': n_cells - n_selected,
              '1': n_selected
          }
      }
      with open(out_path, 'w', encoding='utf-8') as fh:
          json.dump(meta, fh)
      print('OK')
    PYTHON

    begin
      run_with_optional_loom_write_lock(loom_path, already_locked: already_locked) do
        stdout, stderr, status = docker_exec_h5_write_python3!(
          loom_path.to_s, field, selected_path.to_s, out_path.to_s,
          stdin_data: script
        )
        payload = {}
        if out_path.file?
          payload = JSON.parse(File.read(out_path, encoding: 'utf-8'))
        end
        unless status.success? && stdout.strip.start_with?('OK')
          err = payload['displayed_error'] if payload.is_a?(Hash)
          raise(err.presence || stderr.presence || stdout.presence || 'Cell selection write failed')
        end
        unless payload.is_a?(Hash) && payload['name'].present?
          raise 'Cell selection write returned empty metadata'
        end
        payload
      end
    ensure
      File.delete(out_path) if File.exist?(out_path)
    end
  end

  # Write a 1-D string metadata vector. Replaces the dataset if it already exists.
  # Values are staged to a temp JSON file under the loom directory (shared with the run container).
  def self.write_metadata_string_vector!(h5_file, metadata_path, values, already_locked: false)
    field = strip_leading_slash(metadata_path)
    loom_path = Pathname.new(h5_file.to_s)
    staging_path = loom_path.dirname.join(".asap_consensus_write_#{Process.pid}_#{SecureRandom.hex(8)}.json")
    File.write(staging_path, Array(values).map { |v| v.nil? ? "" : v.to_s }.to_json)

    script = <<~PYTHON
      import h5py
      import numpy as np
      import json
      import sys

      loom_path = sys.argv[1]
      field = sys.argv[2]
      values_path = sys.argv[3]
      with open(values_path, 'r', encoding='utf-8') as fh:
          values = json.load(fh)
      arr = np.array(values, dtype=h5py.special_dtype(vlen=str))

      with h5py.File(loom_path, 'r+') as f:
          if field in f:
              del f[field]
          f.create_dataset(field, data=arr)

      print('OK')
    PYTHON

    begin
      run_with_optional_loom_write_lock(loom_path, already_locked: already_locked) do
        stdout, stderr, status = docker_exec_h5_write_python3!(
          loom_path.to_s, field, staging_path.to_s,
          stdin_data: script
        )
        unless status.success? && stdout.strip.start_with?('OK')
          raise "Failed to write metadata #{metadata_path}: #{stderr.presence || stdout}"
        end
      end
      true
    ensure
      File.delete(staging_path) if File.exist?(staging_path)
    end
  end

  def self.strip_leading_slash(path)
    path.to_s.sub(%r{\A/}, '')
  end
  private_class_method :strip_leading_slash
end