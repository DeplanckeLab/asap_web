# frozen_string_literal: true

require 'open3'

class GeneSetItemModuleScore
  LOCAL_COLLECTION_PREFIX = 'local_collection'
  MANUAL_COLLECTION_ID = 'manual_local'

  def initialize(request)
    @request = request
    @project = request.project
  end

  def call
    raise ArgumentError, 'Project is missing' unless @project

    loom_path = project_loom_path
    raise ArgumentError, 'Loom file not found' unless File.exist?(loom_path)

    if local_item?(@request.item_id)
      return LocalGeneSetExpressionScores.new(@project).call(
        item_id_raw: @request.item_id,
        loom_path: loom_path,
        dataset_path: @request.dataset
      )
    end

    run_java_module_score(loom_path)
  end

  private

  def project_loom_path
    @project.data_dir + @request.loom_file
  end

  def local_item?(item_id)
    item_id.to_s.start_with?("#{LOCAL_COLLECTION_PREFIX}:") ||
      item_id.to_s.start_with?("#{MANUAL_COLLECTION_ID}:")
  end

  def run_java_module_score(loom_path)
    item_id = @request.item_id.to_i
    raise ArgumentError, 'Missing gene set item identifier' if item_id <= 0

    db_conn = remote_db_conn
    ensure_remote_item_visible!(item_id)

    cmd = [
      'java',
      '-jar',
      "#{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar",
      '-T', 'ModuleScore',
      '-loom', loom_path.to_s,
      '-geneset', item_id.to_s,
      '-dataset', @request.dataset,
      '-h', db_conn,
      '-m', 'seurat'
    ]

    stdout = ''
    stderr = ''
    status = nil
    Open3.popen3(*cmd) do |stdin, stdout_io, stderr_io, wait_thr|
      stdin.close
      @request.update_column(:pid, wait_thr.pid)

      stdout_reader = Thread.new { stdout_io.read.to_s }
      stderr_reader = Thread.new { stderr_io.read.to_s }

      while wait_thr.alive?
        if @request.reload.canceled?
          terminate_process(wait_thr.pid)
          break
        end
        sleep 0.1
      end

      status = wait_thr.value
      stdout = stdout_reader.value
      stderr = stderr_reader.value
    end

    raise ArgumentError, 'ModuleScore request was canceled' if @request.reload.canceled?
    raise ArgumentError, 'ModuleScore execution did not complete' if status.nil?
    unless status.success?
      stderr_msg = stderr.to_s.strip
      stderr_msg = stderr_msg[0..500] if stderr_msg.length > 500
      raise ArgumentError, stderr_msg.present? ? "ModuleScore execution failed: #{stderr_msg}" : "ModuleScore execution failed (exit status #{status.exitstatus})"
    end

    parsed = Basic.safe_parse_json(stdout, {})
    scores = parsed['scores']
    raise ArgumentError, 'ModuleScore output is invalid' unless scores.is_a?(Array)

    scores
  ensure
    @request.update_column(:pid, nil) if @request&.persisted?
  end

  def remote_db_conn
    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = h_env['asap_data_db_name'].to_s.strip
    raise ArgumentError, 'Missing asap_data_db_name in project version env_json' if db_version.blank?

    conn = nil
    RemoteGene.with_remote(db_version) do
      db_config = RemoteGene.connection_db_config
      cfg = db_config&.configuration_hash || {}
      db_host = cfg[:host] || cfg['host'] || ENV.fetch('ASAP2_REMOTE_HOST')
      db_port = cfg[:port] || cfg['port'] || ENV.fetch('ASAP2_REMOTE_PORT')
      db_name = cfg[:database] || cfg['database'] || db_version
      conn = "#{db_host}:#{db_port}/#{db_name}"
    end
    conn
  end

  def ensure_remote_item_visible!(item_id)
    h_env = Basic.safe_parse_json(@project.version.env_json, {})
    db_version = h_env['asap_data_db_name'].to_s.strip
    raise ArgumentError, 'Missing asap_data_db_name in project version env_json' if db_version.blank?

    current_user_id = @request.user_id
    RemoteGene.with_remote(db_version) do
      conn = RemoteGene.connection
      visibility_sql = [
        '(gs.project_id IS NULL AND gs.ref_id IS NOT NULL)',
        "gs.project_id = #{@project.id}"
      ]
      if current_user_id.present?
        visibility_sql << "(gs.project_id IS NULL AND gs.user_id = #{current_user_id.to_i} AND gs.ref_id IS NULL)"
      end

      item_row = conn.select_one(<<~SQL)
        SELECT gsi.id
        FROM gene_set_items gsi
        JOIN gene_sets gs ON gs.id = gsi.gene_set_id
        WHERE gsi.id = #{item_id}
          AND gs.organism_id = #{@project.organism_id.to_i}
          AND COALESCE(gs.obsolete, FALSE) = FALSE
          AND (#{visibility_sql.join(' OR ')})
      SQL
      raise ArgumentError, 'Gene set item not found' unless item_row
    end
  end

  def terminate_process(pid)
    normalized_pid = pid.to_i
    return if normalized_pid <= 0

    begin
      Process.kill('TERM', normalized_pid)
    rescue Errno::ESRCH
      return
    end

    10.times do
      sleep 0.1
      begin
        Process.getpgid(normalized_pid)
      rescue Errno::ESRCH
        return
      rescue StandardError
        break
      end
    end

    begin
      Process.kill('KILL', normalized_pid)
    rescue Errno::ESRCH, StandardError
      nil
    end
  end
end
