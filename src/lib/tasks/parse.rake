require 'zlib'

desc 'Parse project data (executed by SLURM)'
task :parse, [:project_key] => [:environment] do |t, args|
  puts 'Executing parse...'

  puts ENV["RAILS_ENV"]
  now = Time.now
  logger = Rails.logger
  profile_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  phase_starts = {}
  phase_start = lambda do |name|
    phase_starts[name] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    logger.info("[ParseRake][Profile] START #{name}")
  end
  phase_end = lambda do |name|
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    t0 = phase_starts[name]
    elapsed = t0 ? (t1 - t0) : 0.0
    total = t1 - profile_t0
    logger.info("[ParseRake][Profile] END #{name} elapsed=#{format('%.3f', elapsed)}s total=#{format('%.3f', total)}s")
  end
  puts args[:project_key]

  project_key = args[:project_key]
  project = Project.where(:key => project_key).first
  puts project.to_json
  unless project
    logger.error("[ParseRake] Project with key #{project_key} not found")
    exit 1
  end
 
  version = project.version
  puts version.id
  unless version
    logger.error("[ParseRake] Project #{project_key} has no version")
    exit 1
  end
  
  h_env = Basic.safe_parse_json(version.env_json, {})
  asap_docker_image = Basic.get_asap_docker(version)
  puts asap_docker_image.id
  unless asap_docker_image
    logger.error("[ParseRake] Could not find ASAP docker image for version #{version.id}")
    exit 1
  end
  
  asap_data_db_name = Basic.asap_data_db_name_from_env!(h_env)
  puts asap_data_db_name.to_s

  db_conn = Basic.asap_data_db_url(h_env)
  
  project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
  tmp_dir = project_dir + 'parsing'
  # Create directory with world-writable permissions so Docker container (user 1006) can write to it
  FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
  # Ensure directory is writable by the Java command (runs as user 1006 in Docker container)
  # Use FileUtils.chmod with force option to ensure permissions are set even if directory already exists
  begin
    FileUtils.chmod(0777, tmp_dir)
    logger.info("[ParseRake] Set permissions on #{tmp_dir} to 0777")
  rescue => e
    logger.warn("[ParseRake] Could not set permissions on #{tmp_dir}: #{e.message}")
  end

  parsing_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'parsing').first
  unless parsing_step
    logger.error("[ParseRake] Could not find parsing step for docker image #{asap_docker_image.id}")
    exit 1
  end

  parsing_attrs = Basic.safe_parse_json(project.parsing_attrs_json, {})
  reset_mode = parsing_attrs['reset_mode'] == true || parsing_attrs['reset_mode'].to_s == 'true' || parsing_attrs['reset_mode'].to_s == '1'
  
  # Always use the latest parsing run for this project.
  run = Run.where(:project_id => project.id, :step_id => parsing_step.id).order(created_at: :desc, id: :desc).first
  unless run
    logger.error("[ParseRake] No run found for project #{project_key}")
    exit 1
  end
  
  fu = if project.fu_id
         Fu.find_by(id: project.fu_id)
       else
         Fu.where(:project_id => project.id, :upload_type => 1).first
       end

  fu_upload_dir = fu&.upload_dir_for_project(project)

  if reset_mode
    phase_start.call('reset_cleanup')
    logger.info("[ParseRake] reset_mode enabled for project #{project_key}; full cleanup before parsing")
    logger.info("[ParseRake][Debug] pre-cleanup counts project=#{project.key} runs=#{project.runs.count} annots=#{Annot.where(project_id: project.id).count} ot_projects=#{OtProject.where(project_id: project.id).count} checkpoints=#{Checkpoint.where(project_id: project.id).count}")

    # Batch cleanup for performance:
    # delete run-linked records and annot-linked records with set-based SQL.
    runs_scope = project.runs.where.not(id: run.id)
    annots_scope = Annot.where(project_id: project.id)
    conn = ActiveRecord::Base.connection

    runs_scope.where.not(slurm_job_id: nil).pluck(:id, :slurm_job_id).each do |run_id, slurm_job_id|
      begin
        slurm_service = SlurmService.new(logger: Rails.logger)
        slurm_service.cancel_job(slurm_job_id)
      rescue => e
        logger.error("[ParseRake] Error cancelling SLURM job for run #{run_id}: #{e.message}")
      end
    end

    if conn.data_source_exists?('cla_votes')
      conn.execute(<<~SQL)
        DELETE FROM cla_votes
        WHERE cla_id IN (
          SELECT clas.id
          FROM clas
          INNER JOIN annots ON annots.id = clas.annot_id
          WHERE annots.project_id = #{project.id.to_i}
        )
      SQL
    end
    AnnotCellSet.where(annot_id: annots_scope.select(:id)).delete_all
    Cla.where(annot_id: annots_scope.select(:id)).delete_all
    OtProject.where(project_id: project.id, annot_id: annots_scope.select(:id)).delete_all
    annots_scope.delete_all

    ActiveRun.where(run_id: runs_scope.select(:id)).delete_all
    Fo.where(run_id: runs_scope.select(:id)).delete_all
    DelRun.where(project_id: project.id, run_id: runs_scope.select(:id)).delete_all
    if conn.data_source_exists?('tmp_fos')
      conn.execute("DELETE FROM tmp_fos WHERE run_id IN (SELECT id FROM runs WHERE project_id = #{project.id.to_i} AND id != #{run.id.to_i})")
    end
    runs_scope.delete_all

    # Delete checkpoints and their embedded comments for this project.
    Checkpoint.where(project_id: project.id).delete_all

    # Delete all sub-directories in project directory.
    if File.exist?(project_dir)
      Dir.children(project_dir).each do |entry|
        sub_path = project_dir + entry
        next unless File.directory?(sub_path)
        # Keep FU storage during reset; parsing input symlink points there.
        next if entry == 'fus'
        FileUtils.rm_rf(sub_path)
      end
    end

    # Reset project steps and deduplicate rows.
    ProjectStep.where(project_id: project.id).select(:step_id).distinct.pluck(:step_id).each do |step_id|
      rows = ProjectStep.where(project_id: project.id, step_id: step_id).order(:id).to_a
      if rows.size > 1
        duplicate_ids = rows[0..-2].map(&:id)
        ProjectStep.where(id: duplicate_ids).delete_all if duplicate_ids.any?
      end
      project_step = ProjectStep.where(project_id: project.id, step_id: step_id).order(:id).last
      project_step.update(status_id: nil, error_message: nil, nber_runs_json: '{}') if project_step
      Basic.upd_project_step(project, step_id)
    end
    logger.info("[ParseRake][Debug] post-cleanup counts project=#{project.key} runs=#{project.runs.count} annots=#{Annot.where(project_id: project.id).count} ot_projects=#{OtProject.where(project_id: project.id).count} checkpoints=#{Checkpoint.where(project_id: project.id).count}")

    parsing_attrs.delete('reset_mode')
    project.update(parsing_attrs_json: parsing_attrs.to_json)
    FileUtils.mkdir_p(tmp_dir, mode: 0777) unless File.exist?(tmp_dir)
    FileUtils.chmod(0777, tmp_dir) if File.exist?(tmp_dir)
    # Recreate flow can reuse the same Run row; clear timing fields so wait/elapsed
    # are computed for the current execution only.
    reset_timestamp = Time.current
    run.update(
      status_id: 1,
      error: nil,
      created_at: reset_timestamp,
      submitted_at: reset_timestamp,
      start_time: nil,
      waiting_duration: nil,
      duration: nil,
      process_duration: nil
    )
    logger.info("[ParseRake][Debug] reset_mode timing reset for run #{run.id}")
    project.reload
    phase_end.call('reset_cleanup')
  end
  
  project_step = ProjectStep.find_by(:project_id => project.id, :step_id => parsing_step.id)
  
  # Update run status to running and calculate waiting_duration
  # Set start_time and waiting_duration when parse.rake actually starts executing
  start_time = Time.now
  waiting_duration = run.submitted_at ? (start_time - run.submitted_at).to_f : nil
  
  # Update run status, start_time, and waiting_duration if not already set
  # (SlurmJobMonitorJob might have already set them, but if not, we set them here)
  if run.status_id == 1 || !run.start_time
    run.update(
      status_id: 2,
      start_time: start_time,
      waiting_duration: waiting_duration
    )
    logger.info("[ParseRake] Updated run #{run.id} to running, waiting_duration: #{waiting_duration}")
  end
  logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} entered execution block with run.status_id=#{run.status_id}, start_time=#{run.start_time}")
  
  # Recompute project_step run counters whenever run status changes.
  Basic.upd_project_step(project, parsing_step.id)
  project_step.reload if project_step
  # Keep project_step status in sync in case the aggregate did not set it yet.
  project_step.update(status_id: 2) if project_step && project_step.status_id != 2
  project.update(status_id: 2)
  project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
  logger.info("[ParseRake] Updated project status to running, broadcasting update")
  
  h_data_types = {}
  DataType.all.map{|dt| h_data_types[dt.name] = dt}
  
  h_data_classes = {}
  DataClass.all.map{|dt| h_data_classes[dt.name] = dt; h_data_classes[dt.id] = dt}

  puts "test"
  
  if project
    puts "project.key:" + project.key
    begin
      puts "parse"
  
    p = Basic.safe_parse_json(project.parsing_attrs_json, {})

    output_json_file = project_dir + 'parsing' + "output.json"
    
    filepath = if project.input_filename.present?
                 project_dir + project.input_filename
               else
                 project_dir + ("input." + project.extension)
               end

    # Keep disk and projects.input_filename in sync when the DB still references a
    # name that no longer exists at the project root. Common cases: legacy
    # convert_other_formats ran gunzip (input_file.gz removed, input_file remains) but
    # input_filename was never updated; or an older layout used plain input_file.
    # reset_parsing already reconciles candidates; parse must too or Java fails.
    unless File.exist?(filepath.to_s)
      input_filename_candidates = [
        project.input_filename,
        (fu.upload_file_name if fu),
        'input_file.tar.gz',
        'input_file.tgz',
        'input_file.zip',
        'input_file.gz',
        'input_file'
      ].compact.map(&:to_s).uniq
      resolved_name = input_filename_candidates.find do |candidate|
        candidate.present? && File.exist?(project_dir + candidate)
      end
      if resolved_name
        filepath = project_dir + resolved_name
        if project.input_filename.to_s != resolved_name
          logger.warn("[ParseRake] Missing #{project_dir + project.input_filename}; using #{filepath} and syncing projects.input_filename")
          project.update_column(:input_filename, resolved_name)
        end
      end
    end

    ### write file from hca
    h_output_hca = nil
    if p['provider_project_id'] and p['provider_project_id'] != ''
      cmd = "rails get_loom_from_hca[#{project.key}] 2>&1 > #{tmp_dir + 'get_loom_from_hca.log'}"
      `#{cmd}`
      puts "CMDx: " + cmd
      hca_output_json_file = project_dir + 'parsing' + "get_loom_from_hca.json"
      if File.exist? hca_output_json_file
        h_output_hca = Basic.safe_parse_json(File.read(hca_output_json_file), {})
      else
        h_output_hca = {'status_id' => 4, 'error' => 'An error occured while getting Loom file from HCA'}
      end
    end

    puts h_output_hca.to_json

    if !h_output_hca or h_output_hca['status_id'] != 4

      ### update run with predictions
      if fu.nil?
        logger.warn("[ParseRake] No Fu record found for project #{project.key} (fu_id: #{project.fu_id}), skipping prediction update")
      else
        phase_start.call('load_preparsing_predictions')
        begin
          upload_dir = fu_upload_dir
          output_file = upload_dir + "output.json"
          
          if File.exist?(output_file)
            puts output_file
            h_preparsing = Basic.safe_parse_json(File.read(output_file), {})
            puts h_preparsing.to_json
            if list_group = h_preparsing['list_groups'][0]
              run.update({
                                      :pred_max_ram => (list_group['pred_max_ram'] != '') ? list_group['pred_max_ram'] : nil, 
                                      :pred_process_duration => (list_group['pred_process_duration']) ? list_group['pred_process_duration'] : nil
                                    })
            end
          else
            logger.warn("[ParseRake] Output file not found: #{output_file}")
          end
        rescue => e
          logger.error("[ParseRake] Error reading prediction file: #{e.class} - #{e.message}")
          logger.error(e.backtrace.join("\n")) if e.backtrace
        ensure
          phase_end.call('load_preparsing_predictions')
        end
      end

      ### get parameters (potentially updated by get_loom_from_hca)
      puts project.id

      project = Project.find(project.id)
      p = Basic.safe_parse_json(project.parsing_attrs_json, {})
      puts "h_params2: " + p.to_json

      opts = []
      p['sel_name'] = 'mtx' if p["file_type"] == 'MEX'
      
      # Get file_type to determine if we need to add -col and -header defaults
      # Get file_type from parsing_attrs_json, or fall back to detected_format from preparsing
      file_type = p["file_type"]
      if file_type.blank?
        # Try to get detected_format from preparsing output
        begin
          upload_dir = fu_upload_dir
          output_file = upload_dir + "output.json"
          
          if File.exist?(output_file)
            h_preparsing = Basic.safe_parse_json(File.read(output_file), {})
            detected_format = h_preparsing['detected_format']
            if detected_format.present?
              file_type = detected_format
              logger.info("[ParseRake] Using detected_format from preparsing: #{detected_format}")
            end
          end
        rescue => e
          logger.warn("[ParseRake] Could not read preparsing output to get detected_format: #{e.message}")
        end
      end

      # Legacy parsing compatibility (< v8): reuse the historical conversion path
      # used by the original application to handle archives/compressed/MTX inputs.
      if version.id < 8
        # v8 preparsing pre-extracts MTX archives into fus/<fu_id>/input_file/ and
        # symlinks the project root to it. If a prior failed legacy run mangled
        # the root symlink (e.g. overwrote it with a regular file), fall back to
        # the canonical pre-extracted bundle in the fu upload dir. Matching v8's
        # MTX short-circuit at line 520 below.
        if file_type.to_s.upcase == 'MTX' && fu && fu_upload_dir
          begin
            preparsed_mtx_dir = File.join(fu_upload_dir.to_s, 'input_file')
            if File.directory?(preparsed_mtx_dir) && File.file?(File.join(preparsed_mtx_dir, 'matrix.mtx'))
              filepath = Pathname.new(preparsed_mtx_dir)
              logger.info("[ParseRake] Using pre-extracted MTX bundle from fu upload dir: #{filepath}")
            end
          rescue => e
            logger.warn("[ParseRake] Could not resolve preparsed MTX bundle from fu: #{e.class} - #{e.message}")
          end
        end

        # When preparsing already extracted an archive member, use that path directly instead
        # of passing the archive to Java with a -sel basename (fails for nested paths).
        if fu
          begin
            preparsing_output_file = fu_upload_dir + "output.json"
            if File.exist?(preparsing_output_file)
              h_prep = Basic.safe_parse_json(File.read(preparsing_output_file), {})
              prep_file_path = Basic.resolve_preparsed_input_file_path(fu, h_preparsing: h_prep, project: project)
              if prep_file_path.present?
                archive_path = /\.(tar|tgz|tbz2|txz|zip|bz2|7z)(\..*)?\z/i
                if prep_file_path.match?(archive_path)
                  if %w[H5_10x H5AD LOOM].include?(file_type)
                    filepath = Pathname.new(prep_file_path)
                    logger.info("[ParseRake] Using preparsing file_path for v<8 #{file_type}: #{filepath}")
                  end
                else
                  filepath = Pathname.new(prep_file_path)
                  effective_fmt = Basic.effective_preparsing_file_type(h_prep)
                  if effective_fmt.present?
                    file_type = effective_fmt
                    p['file_type'] = effective_fmt
                  end
                  if file_type.to_s.upcase == 'RAW_TEXT' || prep_file_path.match?(/\.(txt|tsv|csv)(\..*)?\z/i)
                    p.delete('sel_name')
                    p.delete(:sel_name)
                  end
                  logger.info("[ParseRake] Using preparsed member file for v<8 parsing: #{filepath} (file_type=#{file_type})")
                end
              end
              p = Basic.reconcile_archive_sel_name!(p, fu_upload_dir)
            end
          rescue => e
            logger.warn("[ParseRake] Could not resolve preparsing file_path: #{e.class} - #{e.message}")
          end
        end

        # Unpack gzip-wrapped H5AD before legacy convert_other_formats, which would otherwise
        # treat the file as a generic archive and corrupt it (gunzip/tar on a plain .h5ad).
        if file_type == 'H5AD' || filepath.to_s.downcase.end_with?('.h5ad', '.h5ad.gz')
          begin
            magic = File.open(filepath.to_s, 'rb') { |f| f.read(2) }
            if magic&.bytes == [0x1f, 0x8b]
              ungzipped_h5ad = tmp_dir + 'input_file.uncompressed.h5ad'
              Zlib::GzipReader.open(filepath.to_s) do |gz|
                File.open(ungzipped_h5ad.to_s, 'wb') do |out|
                  IO.copy_stream(gz, out)
                end
              end
              filepath = ungzipped_h5ad
              logger.info("[ParseRake] Detected gzipped H5AD input, unpacked to #{filepath} before legacy conversion")
            end
          rescue => e
            logger.error("[ParseRake] Failed to unpack gzipped H5AD #{filepath}: #{e.class} - #{e.message}")
            raise
          end
        end

        skip_legacy_convert = (version.id >= 8 && file_type.to_s.upcase == 'RDS') ||
                              (version.id < 8 &&
                               file_type.to_s.upcase == 'RAW_TEXT' &&
                               Basic.raw_text_matrix_file?(filepath.to_s))

        begin
          if skip_legacy_convert
            reason = file_type.to_s.upcase == 'RDS' ? 'RDS (v8 native parser)' : 'RAW_TEXT matrix'
            logger.info("[ParseRake] Skipping legacy convert_other_formats for #{reason} at #{filepath}")
            conv_res = nil
          else
            conv_res = Basic.convert_other_formats(filepath, logger)
            if conv_res && conv_res[:file_path].present? && conv_res[:file_path].to_s != filepath.to_s
              filepath = conv_res[:file_path]
              logger.info("[ParseRake] Legacy conversion changed input path to #{filepath}")
            end
          end

          converted_type = conv_res && conv_res[:type]
          if converted_type.present?
            # Respect explicit type when already meaningful; otherwise adopt converted type.
            # 'MTX' is listed as a placeholder because the legacy pipeline converts the
            # MTX triplet to an H5 file (type 'MEX' which maps to Java 'H5_10x'); after
            # conversion the original MTX type no longer describes the file on disk.
            convertible_placeholders = ['ARCHIVE', 'ARCHIVE_COMPRESSED', 'COMPRESSED', 'RAW_TEXT', 'MTX']
            if file_type.blank? || convertible_placeholders.include?(file_type)
              file_type = converted_type
              p['file_type'] = converted_type
              logger.info("[ParseRake] Legacy conversion set file_type to #{file_type}")
              # mtx_to_h5.R writes the matrix under the "/mtx" group. The Java
              # parser needs -sel mtx to read that group. Without this, the
              # H5_10x selection fallback below would pick a group from the
              # preparsing list_groups (e.g. "input_file.tar.gz") which is not
              # a real H5 path in the converted file.
              p['sel_name'] = 'mtx' if converted_type == 'MEX' && p['sel_name'].blank?
            end
          end
        rescue => e
          logger.error("[ParseRake] Legacy conversion failed for #{filepath}: #{e.class} - #{e.message}")
          raise
        end

        # After decompress / rename, the real file may be input_file while DB still
        # says input_file.gz; keep projects.input_filename aligned with project root.
        if filepath.parent.expand_path == project_dir.expand_path
          bn = filepath.basename.to_s
          if project.input_filename.to_s != bn
            logger.info("[ParseRake] Syncing projects.input_filename #{project.input_filename.inspect} -> #{bn} (legacy conversion output path)")
            project.update_column(:input_filename, bn)
          end
        end
      end

      # Preparsing can set RAW_TEXT for a Matrix Market coordinate/array body; Java then treats
      # the first line as a single-column header and fails (e.g. expected 30087 columns).
      if version.id < 8 && File.file?(filepath.to_s) && !filepath.to_s.downcase.end_with?('.h5') &&
         Basic.layout_matrix_market_sparse_or_array_file?(filepath.to_s)
        fmt = file_type.to_s.upcase
        if %w[RAW_TEXT RAW].include?(fmt)
          Basic.write_parsing_output_json_displayed_error(
            project_dir,
            logger,
            [
              'Preparsing labeled this file as RAW_TEXT, but it is Matrix Market (MTX) coordinate or array format.',
              'v7 cannot run the text matrix parser on this file. Set the matrix type to MTX if the form allows it, re-upload so preparsing detects MTX, or use parsing with version 8 or later.'
            ]
          )
          raise "Matrix Market input is not compatible with RAW_TEXT parsing for v7 (see parsing/output.json)."
        end
      end

       h_types = {
        'MEX' => "H5_10x",
        'H5_10X' => 'H5_10x'
      }
      # Legacy Java parser reads LOOM, not RDS; v8 parse.v8.py has a native RDS handler.
      h_types['RDS'] = 'LOOM' if version.id < 8
      
      # Ensure H5AD selection is always explicit for Java parsing.
      # Java H5AD parser crashes with a NullPointerException if selection is missing.
       group_names = []
       file_type = (h_types[file_type]) ? h_types[file_type] : file_type

      # ASAP.jar has no -type MTX. Real MTX must become H5 via convert_other_formats
      # (then file_type is MEX -> H5_10x). If preparsing said MTX but conversion did not
      # yield input.h5, Java would fail with "This file type 'MTX' does not exist."
      if version.id < 8 && file_type.to_s.upcase == 'MTX'
        fp_s = filepath.to_s
        if fp_s.downcase.end_with?('.h5')
          file_type = 'H5_10x'
          p['sel_name'] = 'mtx' if p['sel_name'].blank?
          logger.info("[ParseRake] MTX preparsing with H5 on disk at #{filepath}; using Java type H5_10x")
        elsif fp_s.downcase.end_with?('.mtx') && File.file?(fp_s)
          raise "Matrix Market .mtx is not accepted directly by Java; mtx_to_h5 did not produce input.h5. Ensure matrix.mtx is in a 10x-style folder layout with barcodes and features."
        else
          mtx_header = if File.file?(fp_s)
                         begin
                           File.open(fp_s, 'r') { |f| f.readline }.to_s.strip
                         rescue StandardError
                           ''
                         end
                       else
                         ''
                       end
          if mtx_header.start_with?('%%MatrixMarket')
            raise "Preparsing decoded this Matrix Market file and showed a dense tab preview, but the file on disk is still sparse Matrix Market (starts with %%MatrixMarket). The v7 Java step cannot read that as RAW_TEXT (first line is not a tab- or comma-separated header). Use a version with the Python parser path, or upload a 10x-style matrix.mtx folder, or export a dense matrix text file."
          end
          logger.warn("[ParseRake] file_type MTX but path #{filepath} is not H5 or .mtx; preparsing may have misclassified. Using RAW_TEXT for Java.")
          file_type = 'RAW_TEXT'
        end
      end

       if version.id < 8 && ['H5AD', 'H5_10x'].include?(file_type) && p['sel_name'].blank?
         begin
          upload_dir = fu_upload_dir
          output_file = upload_dir + "output.json"
          h_preparsing = File.exist?(output_file) ? Basic.safe_parse_json(File.read(output_file), {}) : {}
          list_groups = Array(h_preparsing['list_groups'])
          group_names = list_groups.map { |g| g['group'].to_s }.reject(&:blank?)

          if group_names.include?('X')
            p['sel_name'] = 'X'
          elsif group_names.size == 1
            p['sel_name'] = group_names.first
          else
            raise "Missing H5AD matrix selection: please select a matrix group before parsing #{h_preparsing.to_json}."
          end
        rescue => e
          logger.error("[ParseRake] Could not determine H5AD selection for project #{project.key}: #{e.class} - #{e.message}")
          raise
        end
      end
      p['sel_name'] = 'mtx' if version.id < 8 && file_type == 'MEX' && p['sel_name'].blank?
      tmp_sel_name = group_names.first if group_names.size == 1
      sel_for_java = p['sel_name'].presence || tmp_sel_name
      opts.push({'opt' => "-sel", 'value' => sel_for_java}) if sel_for_java.present?

      # Java H5AD: -ngenes/-ncells must match the selected layer. parsing_attrs can still
      # hold dimensions from preparsing preview of a different matrix.
      if version.id < 8 && fu && ['H5AD', 'H5_10x'].include?(file_type)
        begin
          preparsing_output = fu_upload_dir + 'output.json'
          if File.exist?(preparsing_output.to_s) && sel_for_java.present?
            h_preparsing = Basic.safe_parse_json(File.read(preparsing_output), {})
            list_groups = Array(h_preparsing['list_groups'])
            if list_groups.any?
              norm = ->(s) { s.to_s.strip.delete_prefix('/').delete_suffix('/').tr('\\', '/') }
              sel_n = norm.call(sel_for_java)
              candidates = [sel_n]
              candidates << sel_n.sub(/\Alayers\//, '') if sel_n.start_with?('layers/')
              candidates << "layers/#{sel_n}" unless sel_n.start_with?('layers/')
              candidates.uniq!
              matched = list_groups.find do |g|
                g.is_a?(Hash) && g['group'].present? && candidates.include?(norm.call(g['group']))
              end
              if matched
                nr = matched['nber_rows'] || matched['nb_genes']
                nc = matched['nber_cols'] || matched['nb_cells']
                if nr.present? && nc.present?
                  p['nber_rows'] = nr.to_i
                  p['nber_cols'] = nc.to_i
                  logger.info("[ParseRake] Synced nber_rows/nber_cols from preparsing for sel=#{sel_for_java}: #{p['nber_rows']} x #{p['nber_cols']}")
                end
              else
                logger.warn("[ParseRake] No preparsing list_groups row matched sel=#{sel_for_java.inspect}; Java will use parsing_attrs nber_rows=#{p['nber_rows']} nber_cols=#{p['nber_cols']}")
              end
            end
          end
        rescue => e
          logger.warn("[ParseRake] Could not sync H5AD dimensions from preparsing: #{e.class} #{e.message}")
        end
      end

      if version.id < 8 && file_type == 'H5AD'
        phase_start.call('h5ad_csc_to_csr')
        filepath = Pathname.new(
          H5adJavaPrep.prepare_parse_work_copy!(filepath.to_s, workdir: tmp_dir, logger: logger)
        )
        phase_end.call('h5ad_csc_to_csr')
      end

      # Only add -col and -header for RAW_TEXT file type
      if file_type == 'RAW_TEXT'
        if version.id < 8 && fu
          filepath = Basic.materialize_raw_text_matrix_for_parse!(
            filepath: filepath,
            fu: fu,
            parsing_attrs: p,
            tmp_dir: tmp_dir,
            logger: logger
          )
        end

        # -col parameter: gene name column (default: "first" if not specified)
        gene_name_col = p["gene_name_col"]
        if gene_name_col.blank? || gene_name_col == 'NA' || gene_name_col == 'none'
          gene_name_col = 'first'  # Default to first column
        end
        opts.push({'opt' => "-col", 'value' => gene_name_col})
        
        # -header parameter: whether file has header row (default: true if not specified)
        has_header = p['has_header']
        if has_header.nil? || has_header == ''
          has_header = '1'  # Default to true (has header)
        end
        header_value = (has_header.to_s == '1' || has_header.to_s == 'true') ? 'true' : 'false'
        opts.push({'opt' => "-header", 'value' => header_value})

        if File.file?(filepath.to_s)
          dims = Basic.raw_text_matrix_dimensions(
            filepath.to_s,
            gene_name_col: gene_name_col,
            delimiter: p['delimiter'],
            has_header: has_header
          )
          if dims[:nber_rows].to_i.positive? && dims[:nber_cols].to_i.positive?
            if p['nber_cols'].to_i != dims[:nber_cols].to_i || p['nber_rows'].to_i != dims[:nber_rows].to_i
              logger.warn(
                "[ParseRake] Syncing RAW_TEXT dimensions from file header for Java: " \
                "preparsing attrs #{p['nber_rows']}x#{p['nber_cols']} -> #{dims[:nber_rows]}x#{dims[:nber_cols]} " \
                "(file #{filepath})"
              )
            end
            p['nber_cols'] = dims[:nber_cols]
            p['nber_rows'] = dims[:nber_rows]
          end
        end
      end
      
      opts.push({'opt' => "-d", 'value' => p["delimiter"]}) if p["delimiter"] and p['delimiter'] != ''
      
      # In Ruby, empty string is truthy for `if p['rowname_metadata']`, which produced
      # `--row-names` with no value so the next argv token (`--col-names`) was consumed
      # as the row path and failed as "`--col-names` does not exist in the input H5ad file."
      opts.push({'opt' => '--row-names', 'value' => p['rowname_metadata']}) if p['rowname_metadata'].to_s.strip.present?
      opts.push({'opt' => '--col-names', 'value' => p['colname_metadata']}) if p['colname_metadata'].to_s.strip.present?

      opts += [
               {'opt' => "-ncells", 'value' => p["nber_cols"]},
               {'opt' => "-ngenes", 'value' => p["nber_rows"]},
               {'opt' => '-T', 'value' => "Parsing"},
               {'opt' => "-organism", 'value' => project.organism_id},
               {'opt' => "-o", 'value' => tmp_dir},
               {'opt' => "-f", 'value' => filepath},
               {'opt' => '-h', 'value' => db_conn}
              ]
      
      # Add -type option - use detected_format if file_type is not set
      # Map common format names to Java command format names
      file_type_value = if file_type.present?
                          (h_types[file_type]) ? h_types[file_type] : file_type
                        else
                          # Default to RAW_TEXT if nothing is available
                          logger.warn("[ParseRake] No file_type found, defaulting to RAW_TEXT")
                          "RAW_TEXT"
                        end
      
      # -type is mandatory according to Java command, so always include it
      opts.push({'opt' => "-type", 'value' => file_type_value})
      puts "toto"
      
      if version.id >= 8

        # For RAW_TEXT uploads packaged in archives (.tar.gz/.zip), preparsing can
        # extract the real matrix file and expose it in output.json:file_path.
        # Use that resolved path for v8 parser instead of the archive itself.
        if file_type == 'RAW_TEXT' && fu
          begin
            preparsing_output_file = fu_upload_dir + "output.json"
            if File.exist?(preparsing_output_file)
              h_preparsing = Basic.safe_parse_json(File.read(preparsing_output_file), {})
              preparsed_file_path = h_preparsing['file_path'].to_s
              if preparsed_file_path.present?
                staging_dir = fu.global_upload_dir.to_s
                if preparsed_file_path.start_with?(staging_dir)
                  rest = preparsed_file_path.delete_prefix(staging_dir).sub(/\A\/+/, '')
                  preparsed_file_path = File.join(fu_upload_dir.to_s, rest)
                end
                if File.exist?(preparsed_file_path)
                  filepath = Pathname.new(preparsed_file_path)
                  logger.info("[ParseRake] Using preparsed RAW_TEXT file path #{filepath} instead of archive input")
                else
                  logger.warn("[ParseRake] Preparsing file_path not found on disk: #{preparsed_file_path}, keeping original input #{filepath}")
                end
              end
            end
          rescue => e
            logger.warn("[ParseRake] Could not resolve preparsed RAW_TEXT file path: #{e.class} - #{e.message}")
          end
        end

        if file_type.to_s.upcase == 'MTX' && fu
            staging_dir = fu.global_upload_dir.to_s
            preparsing_output_file = fu_upload_dir + "output.json"
            if File.exist?(preparsing_output_file)
              h_mtx_prep = Basic.safe_parse_json(File.read(preparsing_output_file), {})
              raw_fp = h_mtx_prep['file_path']
              prep_paths =
                if raw_fp.is_a?(Array)
                  raw_fp.map(&:to_s).map(&:strip).reject(&:blank?)
                else
                  [raw_fp.to_s.strip].reject(&:blank?)
                end
              prep_paths.each do |prep_p|
                if prep_p.start_with?(staging_dir)
                  rest = prep_p.delete_prefix(staging_dir).sub(/\A\/+/, '')
                  prep_p = File.join(fu_upload_dir.to_s, rest)
                end
                next unless prep_p.downcase.end_with?('.mtx') && File.file?(prep_p)

                filepath = Pathname.new(prep_p)
                logger.info("[ParseRake] Using preparsed MTX matrix path #{filepath} for v8 parsing")
                break
              end
            end

            fp_s = filepath.to_s
            fp_resolved = begin
              File.realpath(fp_s)
            rescue StandardError
              fp_s
            end
            if File.directory?(fp_resolved)
              matrix_candidate = File.join(fp_resolved, 'matrix.mtx')
              unless File.file?(matrix_candidate)
                mtx_list = Dir[File.join(fp_resolved, '*.mtx')].select { |p| File.file?(p) }
                matrix_candidate = mtx_list.size == 1 ? mtx_list.first : nil
              end
              if matrix_candidate.present? && File.file?(matrix_candidate)
                filepath = Pathname.new(matrix_candidate)
                logger.info("[ParseRake] MTX project input is a directory; using matrix file #{filepath}")
              end
            end

            mtx_final = filepath.to_s
            unless mtx_final.downcase.end_with?('.mtx') && File.file?(mtx_final)
              bundle_dir = fu_upload_dir + 'input_file'
              if bundle_dir.directory?
                bd = begin
                  File.realpath(bundle_dir.to_s)
                rescue StandardError
                  bundle_dir.to_s
                end
                matrix_candidate = File.join(bd, 'matrix.mtx')
                unless File.file?(matrix_candidate)
                  mtx_list = Dir[File.join(bd, '*.mtx')].select { |p| File.file?(p) }
                  matrix_candidate = mtx_list.size == 1 ? mtx_list.first : nil
                end
                if matrix_candidate.present? && File.file?(matrix_candidate)
                  filepath = Pathname.new(matrix_candidate)
                  logger.info("[ParseRake] MTX matrix resolved from Fu bundle directory #{filepath}")
                end
              end
            end

            mtx_final = filepath.to_s
            unless mtx_final.downcase.end_with?('.mtx') && File.file?(mtx_final)
              logger.error("[ParseRake] v8 MTX: could not resolve a .mtx file; last candidate was #{filepath.inspect}")
              raise "v8 MTX parsing requires a readable path to a .mtx file; resolved input was #{filepath.inspect}"
            end
        end


#      usage: parse.v8.py -f File to parse [-o Output folder] --filetype File type [--header [RAW_TEXT] Is there a header] [--col [RAW_TEXT] Which column contains row names]                 
#                   [--sel In case of multiple matrices, which one to use] [--delim [RAW_TEXT] Delimiter to parse columns] --organism Organism --dburl Host URL for DB                        
#                   (format HOST:PORT/DB)                                                                                                                                                     
#parse.v8.py: error: the following arguments are required: -f, --filetype, --organism, --dburl                                                                                                

        opts = []
        sel_name = p['sel_name'] || p[:sel_name] || p['sel'] || p[:sel]
        if file_type == 'H5AD' && sel_name.present? && !sel_name.start_with?('/')
          sel_name = (sel_name == 'X') ? '/X' : "/layers/#{sel_name}"
        end
        opts.push({'opt' => "--sel", 'value' => sel_name}) if sel_name.present?
        if file_type == 'RAW_TEXT'
          gene_name_col = p['gene_name_col'] || p[:gene_name_col] || 'first'
          has_header = p['has_header'] || p[:has_header]
          header_value = (has_header == '1' || has_header == true || has_header == 'true') ? 'true' : 'false'
          opts.push({'opt' => "--col", 'value' => gene_name_col}) if gene_name_col
          opts.push({'opt' => "--header", 'value' => header_value})
        end

        opts.push({'opt' => "--delim", 'value' => p["delimiter"]}) if p["delimiter"] and p['delimiter'] != ''

        #opts.push({'opt' => '--row-names', 'value' => p['rowname_metadata']}) if p['rowname_metadata']                                                                                       
        #opts.push({'opt' => '--col-names', 'value' => p['colname_metadata']}) if p['colname_metadata']                                                                                       

        opts += [
          #          {'opt' => "-ncells", 'value' => p["nber_cols"]},                                                                                                                         
          #          {'opt' => "-ngenes", 'value' => p["nber_rows"]},                                                                                                                         
          {'opt' => "--organism", 'value' => project.organism_id},
          {'opt' => "--filetype", 'value' => file_type},
          {'opt' => "-o", 'value' => tmp_dir},
          {'opt' => "-f", 'value' => filepath},
          {'opt' => '--dburl', 'value' => db_conn}
        ]


        h_env_docker_image = h_env['docker_images']['asap_run']
        image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']
        docker_call = h_env_docker_image['call'].gsub(/\#image_name/, image_name)
        user_data_mount = ENV.fetch('USER_DATA_DIR')
        mount_arg = "-v #{user_data_mount}:#{user_data_mount}"
        unless docker_call.include?(mount_arg)
          docker_call = docker_call.sub('--rm', "--rm #{mount_arg}")
        end

        asap_instance_name = ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev')
        h_cmd_parse = {
          'host_name' => "localhost",
          'time_call' => h_env["time_call"].gsub(/\#output_dir/, tmp_dir.to_s),
          'container_name' => asap_instance_name + "_" + run.id.to_s,
          'docker_call' => docker_call,
          'program' => "python3 parse.v8.py",
          'opts' => opts,
          'args' => []
        }

        # Persist the real container command (not the rails parse[...] SLURM wrapper).
        run.update_columns(command_json: h_cmd_parse.to_json)

#        output_file = tmp_dir + "output.loom"                                                                                                                                                
#        output_json = tmp_dir + "output.json"                                                                                                                                                

        puts h_cmd_parse
        cmd_parse = Basic.build_cmd(h_cmd_parse)
        puts "CMD_PYTHON:" + cmd_parse
        phase_start.call('parse_python_command')
        parse_stdout = `#{cmd_parse} 2>&1`
        cmd_exitstatus = $?.exitstatus
        logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} python parse command finished with exitstatus=#{cmd_exitstatus}")

        output_json_v8 = tmp_dir + 'output.json'
        if File.exist?(output_json_v8)
          logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} output_json size=#{File.size(output_json_v8)} mtime=#{File.mtime(output_json_v8)}")
        else
          logger.error("[ParseRake][Debug] project=#{project.key} run=#{run.id} expected output_json missing at #{output_json_v8}")
        end
        phase_end.call('parse_python_command')

        unless cmd_exitstatus == 0
          begin
            error_payload = {
              displayed_error: parse_stdout.present? ? parse_stdout : "Python parser failed with exit status #{cmd_exitstatus}"
            }
            File.open(output_json_v8, 'w') { |fw| fw.write(error_payload.to_json) }
          rescue => write_err
            logger.error("[ParseRake] Failed to persist parser error output to #{output_json_v8}: #{write_err.class} - #{write_err.message}")
          end
          logger.error("[ParseRake] Python parsing command failed for project #{project.key} run #{run.id} with exitstatus=#{cmd_exitstatus}")
          logger.error("[ParseRake] Python parser output: #{parse_stdout}") if parse_stdout.present?
          exit cmd_exitstatus
        end
        exit 0
      end

      
      mem = p["nber_cols"].to_i * p["nber_rows"].to_i * 128 / (31053 * 1474560)
      h_env_docker_image = h_env['docker_images']['asap_run']
      image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']
            
      asap_instance_name = ENV.fetch('ASAP_INSTANCE_NAME', 'asap_dev')
      h_cmd_parse = {
        'host_name' => "localhost",
        'time_call' => h_env["time_call"].gsub(/\#output_dir/, tmp_dir.to_s),
        'container_name' => asap_instance_name + "_" + run.id.to_s,
        'docker_call' => h_env_docker_image['call'].gsub(/\#image_name/, image_name),
        'program' => "java -jar ASAP.jar",
        'opts' => opts,
        'args' => []
      }

      # Persist the real container command (not the rails parse[...] SLURM wrapper).
      run.update_columns(command_json: h_cmd_parse.to_json)

      output_file = tmp_dir + "output.loom"
      output_json = tmp_dir + "output.json"

      puts h_cmd_parse
      cmd_parse = Basic.build_cmd(h_cmd_parse)
      puts "CMD_JAVA:" + cmd_parse
      phase_start.call('parse_java_command')
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} executing parse command")
      `#{cmd_parse}`
      cmd_exitstatus = $?.exitstatus
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} parse command finished with exitstatus=#{cmd_exitstatus}")
      unless File.exist?(output_json)
        logger.error("[ParseRake][Debug] project=#{project.key} run=#{run.id} expected output_json missing at #{output_json}")
      end
      if File.exist?(output_json)
        logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} output_json size=#{File.size(output_json)} mtime=#{File.mtime(output_json)}")
      end
      h_parsing = Basic.safe_parse_json(File.read(output_json), {})
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} parsed output_json keys=#{h_parsing.keys.sort.join(',')}")
      phase_end.call('parse_java_command')
      if  p["file_type"] == 'MEX'
        h_parsing['detected_format'] = 'MEX'
        File.open(output_json, 'w') do |fw|
          fw.write(h_parsing.to_json)
        end
      end

      exec_run_details_file = tmp_dir + 'exec_run_details.log'
      timing = Basic.parse_exec_run_details(exec_run_details_file)
      max_ram_mb = timing[:max_ram_mb]
      process_duration_seconds = timing[:process_duration_seconds]
      if timing[:time_info].present?
        logger.info("[ParseRake] Parsed time info: #{timing[:time_info].to_json}")
      else
        logger.warn("[ParseRake] exec_run_details.log not found at #{exec_run_details_file}")
      end
      
      # Calculate duration from start_time if available
      duration_seconds = nil
      if run.start_time
        duration_seconds = (Time.now - run.start_time).to_f
        logger.info("[ParseRake] Calculated duration from start_time: #{duration_seconds} seconds")
      end
      
      # Parsing is complete - call finish_run to create annotations (including matrix annotation)
      # finish_run will set status_id = 3 and create all necessary annotations
      # finish_run builds h_output_files from step.output_json (expected_outputs) and files in output_dir
      # It uses h_results['nber_rows'] and h_results['nber_cols'] for matrix dimensions
      logger.info("[ParseRake] Calling Basic.finish_run to create annotations for run #{run.id}")
      logger.info("[ParseRake] h_parsing has nber_rows=#{h_parsing['nber_rows']}, nber_cols=#{h_parsing['nber_cols']}")
      
      # Call finish_run with h_parsing as h_results.
      # skip_broadcast: true because finish_run broadcasts before we update project.status_id,
      # so we do a single broadcast below with the correct project status.
      phase_start.call('finish_run')
      begin
        logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} calling Basic.finish_run")
        Basic.finish_run(logger, run, h_parsing, skip_broadcast: true)
        logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} Basic.finish_run returned")
      rescue => e
        logger.error("[ParseRake][Debug] project=#{project.key} run=#{run.id} Basic.finish_run raised #{e.class}: #{e.message}")
        logger.error("[ParseRake][Debug] project=#{project.key} run=#{run.id} finish_run backtrace: #{e.backtrace.first(10).join("\n")}") if e.backtrace
        raise
      ensure
        phase_end.call('finish_run')
      end
      
      # Reload run to get updated status and metrics from finish_run
      run.reload
      logger.info("[ParseRake][Debug] project=#{project.key} run=#{run.id} after finish_run reload status_id=#{run.status_id}, duration=#{run.duration}, process_duration=#{run.process_duration}")
      
      # Update metrics that finish_run doesn't handle (max_ram, process_duration from exec_run_details.log)
      run_updates = {}
      run_updates[:max_ram] = max_ram_mb if max_ram_mb && run.max_ram != max_ram_mb
      run_updates[:process_duration] = process_duration_seconds if process_duration_seconds && run.process_duration != process_duration_seconds
      run.update(run_updates) if run_updates.any?
      
      annot_count = Annot.where(run_id: run.id).count
      logger.info("[ParseRake] finish_run completed for run #{run.id}, status_id=#{run.status_id}, annotations created: #{annot_count}")
      
      # Visualization (embedding menu) shows cells x genes via project.gene_count / cell_count, which
      # read projects.nber_rows / nber_cols. Those columns were only set from the create-project form;
      # refresh them from the authoritative parsing output so they match the matrix annot.
      project.reload
      status_update = { status_id: 3 }
      nr = h_parsing['nber_rows'] || h_parsing[:nber_rows]
      nc = h_parsing['nber_cols'] || h_parsing[:nber_cols]
      if nr.present? && nc.present?
        status_update[:nber_rows] = nr.to_i
        status_update[:nber_cols] = nc.to_i
        pa = Basic.safe_parse_json(project.parsing_attrs_json, {})
        pa['nber_rows'] = nr.to_i
        pa['nber_cols'] = nc.to_i
        status_update[:parsing_attrs_json] = pa.to_json
        logger.info("[ParseRake] Updated project nber_rows/nber_cols from parsing output: #{nr.to_i} x #{nc.to_i}")
      end
      project.update(status_update)
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      logger.info("[ParseRake] Parsing completed, broadcasting update")

      ## 
      puts "Define project cell set"
      phase_start.call('update_project_cell_set')
      Basic.upd_project_cell_set(project)
      project.reload
      phase_end.call('update_project_cell_set')
      if project.project_cell_set
        puts "=> " + project.project_cell_set.key
      else
        logger.warn("[ParseRake] Project cell set not created for project #{project.key}")
      end

      h_parsing_metadata = {}
      puts h_parsing.to_json
      if h_parsing['metadata']
        h_parsing['metadata'].each do |meta|
          h_parsing_metadata[meta['name']] = 1
        end
      end
      if fu.nil?
        logger.warn("[ParseRake] No Fu record found for project #{project.key} (fu_id: #{project.fu_id}), cannot proceed with metadata copying")
      else
        phase_start.call('metadata_copying')
        upload_dir = fu_upload_dir
        output_file = upload_dir + "output.json"
        output_path = project_dir + "parsing" + "output.loom"
        ori_fu_path = fu_upload_dir + fu.upload_file_name
        puts ori_fu_path
        h_preparsing = Basic.safe_parse_json(File.read(output_file), {})
        puts h_preparsing.to_json
        puts "bla"
        
        # Check if metadata copying is needed and broadcast start
        needs_metadata_copying = false
        if h_preparsing && h_preparsing["detected_format"]
          if (["RDS", "LOOM"].include?(h_preparsing["detected_format"]) && 
              h_preparsing["list_groups"] && h_preparsing["list_groups"][0] && 
              h_preparsing["list_groups"][0]["existing_metadata"]) ||
             (["H5AD"].include?(h_preparsing["detected_format"]) && 
              h_parsing["existing_metadata"])
            needs_metadata_copying = true
          end
        end
        
        # Broadcast metadata copying start if needed, or mark as complete if not needed
        if needs_metadata_copying
          ActionCable.server.broadcast "project_#{project.id}", {
            project_id: project.id,
            step_id: parsing_step.id,
            stage: 'creation',
            parsing_status: 'complete',
            parsing_complete: true,
            metadata_status: 'running',
            metadata_complete: false,
            project_key: project.key
          }
          logger.info("[ParseRake] Metadata copying starting, broadcasting update")
        else
          # No metadata copying needed - mark as complete immediately
          ActionCable.server.broadcast "project_#{project.id}", {
            project_id: project.id,
            step_id: parsing_step.id,
            stage: 'creation',
            parsing_status: 'complete',
            parsing_complete: true,
            metadata_status: 'complete',
            metadata_complete: true,
            all_complete: true,
            redirect_url: Rails.application.routes.url_helpers.project_path(project),
            project_key: project.key
          }
          logger.info("[ParseRake] No metadata copying needed, marking as complete")
        end

        if ["H5AD"].include?(h_preparsing["detected_format"]) && h_parsing["existing_metadata"]
          phase_start.call('metadata_copy_h5ad')
          list_metadata = h_parsing["existing_metadata"].select{|e| !h_parsing_metadata[e]}
          if list_metadata
            relative_filepath = Basic.relative_path(project, output_path)
            list_metadata.each do |meta|
              meta['imported'] = true
              puts "add annot #{meta.to_json}"
              Basic.load_annot(run, meta, relative_filepath, h_data_types, h_data_classes, logger)
            end
          end
          phase_end.call('metadata_copy_h5ad')
        elsif ["RDS"].include? h_preparsing["detected_format"]  and h_preparsing["list_groups"][0]["existing_metadata"]
          phase_start.call('metadata_copy_rds')
          h_meta = {:meta => h_preparsing["list_groups"][0]["existing_metadata"].select{|e| !h_parsing_metadata[e]}}
          metadata_list_file = tmp_dir + 'list_metadata_to_copy.json'
          File.open(metadata_list_file, 'w') do |f|
            f.write(h_meta.to_json)
          end
          cmd = "java -jar lib/ASAP.jar -T CopyMetaData -loomFrom \"#{filepath}\" -loomTo #{output_path} -metaJSON #{metadata_list_file}"
          puts cmd
          output = `#{cmd}`
          metadata_list_file2 = tmp_dir + 'list_metadata_to_copy2.json'
          File.open(metadata_list_file2, 'w') do |f|
            f.write(output)
          end
          cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -no-values -loom #{output_path} -metaJSON #{metadata_list_file2}"
          puts cmd
          output = `#{cmd}`
          h_res = Basic.safe_parse_json(output, {})
          puts output
          puts h_res.to_json
          
          if list_metadata = h_res["list_meta"]
            relative_filepath = Basic.relative_path(project, output_path)
            list_metadata.each do |meta|
              meta['imported'] = true
              puts "add annot #{meta.to_json}"
              Basic.load_annot(run, meta, relative_filepath, h_data_types, h_data_classes, logger)
            end
          end
          phase_end.call('metadata_copy_rds')
        elsif ["LOOM"].include? h_preparsing["detected_format"]  and h_preparsing["list_groups"][0]["existing_metadata"]
          phase_start.call('metadata_copy_loom')
          puts "bou"
          h_meta = {:meta => h_preparsing["list_groups"][0]["existing_metadata"].select{|e| !h_parsing_metadata[e]}}
          metadata_list_file = tmp_dir + 'list_metadata_to_copy.json'
          File.open(metadata_list_file, 'w') do |f|
            f.write(h_meta.to_json)
          end
          cmd = "java -jar lib/ASAP.jar -T CopyMetaData -loomFrom \"#{ori_fu_path}\" -loomTo #{output_path} -metaJSON #{metadata_list_file}"
          puts cmd
          output = `#{cmd}`
          metadata_list_file2 = tmp_dir + 'list_metadata_to_copy2.json'
          File.open(metadata_list_file2, 'w') do |f|
            f.write(output)
          end
          cmd = "java -jar lib/ASAP.jar -T ExtractMetadata -no-values -loom #{output_path} -metaJSON #{metadata_list_file2}"
          puts cmd
          output = `#{cmd}`
          h_res = Basic.safe_parse_json(output, {})
          puts output 
          puts h_res.to_json
          if list_metadata = h_res['list_meta']
            relative_filepath = Basic.relative_path(project, output_path)
            list_metadata.each do |meta|
              meta['imported'] = true
              puts "add annot #{meta.to_json}" 
              Basic.load_annot(run, meta, relative_filepath, h_data_types, h_data_classes, logger)
            end
          end
          phase_end.call('metadata_copy_loom')
        end

        # Broadcast completion after metadata copying (or if no metadata copying was needed)
        # If metadata copying was needed, it's now complete; if not needed, mark as complete
        ActionCable.server.broadcast "project_#{project.id}", {
          project_id: project.id,
          step_id: parsing_step.id,
          stage: 'creation',
          parsing_status: 'complete',
          parsing_complete: true,
          metadata_status: 'complete',
          metadata_complete: true,
          all_complete: true,
          redirect_url: Rails.application.routes.url_helpers.project_path(project),
          project_key: project.key
        }
        project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
        logger.info("[ParseRake] Parse and metadata copying completed, broadcasting final update")
        phase_end.call('metadata_copying')
      end

    else
      h_output = {"displayed_error" => ["Error retrieving data from HCA", h_output_hca["error"]]}
            
      ##write HCA error in output.json
      File.open(output_json_file, 'w') do |f|
        f.write h_output.to_json
      end
      
      # Broadcast error
      project_step.update(status_id: 4) if project_step
      Basic.upd_project_step(project, parsing_step.id)
      project.update(status_id: 4)
      project.broadcast(parsing_step.id) if project.respond_to?(:broadcast)
      logger.error("[ParseRake] HCA error occurred, broadcasting failure")
    end
    ensure
      if fu
        begin
          upload_dir_to_cleanup = fu_upload_dir
          global_upload_root = Fu.global_upload_root.to_s
          cleanup_allowed = upload_dir_to_cleanup.to_s.start_with?(global_upload_root + "/")
          if cleanup_allowed && File.exist?(upload_dir_to_cleanup)
            FileUtils.rm_rf(upload_dir_to_cleanup)
            logger.info("[ParseRake] Cleaned upload directory #{upload_dir_to_cleanup} after parsing")
          elsif !cleanup_allowed
            logger.info("[ParseRake] Skipping cleanup for project-attached upload directory #{upload_dir_to_cleanup}")
          end
        rescue => e
          logger.error("[ParseRake] Failed to clean upload directory for Fu##{fu.id}: #{e.class} - #{e.message}")
        end
      end
    end
  end
end
