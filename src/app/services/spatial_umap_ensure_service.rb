# frozen_string_literal: true

# For spatial datasets that were parsed without an imported UMAP embedding,
# run Scanpy PCA on /matrix then Scanpy UMAP on that PCA.
class SpatialUmapEnsureService
  PCA_STEP_NAME = 'pca_sc'
  UMAP_STEP_NAME = 'umap'
  PCA_STD_METHOD_NAME = 'scanpy'
  UMAP_STD_METHOD_NAME = 'scanpy'
  AUTO_ATTR = 'auto_spatial_from_matrix'
  NBER_DIMS = 50
  DEFAULT_TIMEOUT_SEC = 6 * 60 * 60
  POLL_INTERVAL_SEC = 15
  UMAP_NAME = /(?:\b|_)umap(?:\b|_)/i
  PCA_NAME = /(?:\b|_)pca(?:\b|_)/i

  Result = Struct.new(:skipped, :reason, :pca_run, :umap_run, :error, keyword_init: true)

  def self.call(project:, logger: Rails.logger, wait: false, user_id: nil, timeout_sec: DEFAULT_TIMEOUT_SEC)
    new(project: project, logger: logger, wait: wait, user_id: user_id, timeout_sec: timeout_sec).call
  end

  def self.after_pca_success(logger, project, pca_run)
    new(
      project: project,
      logger: logger,
      wait: false,
      user_id: pca_run.user_id,
      timeout_sec: DEFAULT_TIMEOUT_SEC
    ).start_umap_after_pca(pca_run)
  end

  def initialize(project:, logger:, wait:, user_id:, timeout_sec: DEFAULT_TIMEOUT_SEC)
    @project = project
    @logger = logger
    @wait = wait
    @user_id = user_id || project.user_id
    @timeout_sec = timeout_sec
  end

  def call
    unless spatial_dataset?
      return Result.new(skipped: true, reason: 'not_spatial')
    end
    if umap_exists?
      return Result.new(skipped: true, reason: 'umap_present')
    end

    matrix = matrix_annot
    if matrix.nil?
      return Result.new(skipped: true, reason: 'no_matrix', error: 'No /matrix annot found')
    end

    pca_run = ensure_pca_run!(matrix)
    return Result.new(skipped: false, pca_run: pca_run, error: @error) if @error

    if @wait
      wait_for_run!(pca_run, 'PCA')
      pca_run.reload
    end

    unless run_success?(pca_run)
      return Result.new(skipped: false, pca_run: pca_run) unless @wait

      return Result.new(skipped: false, pca_run: pca_run, error: @error || "PCA run #{pca_run.id} did not succeed")
    end

    umap_run = start_umap_after_pca(pca_run)
    return Result.new(skipped: false, pca_run: pca_run, umap_run: umap_run, error: @error) if @error

    if @wait && umap_run
      wait_for_run!(umap_run, 'UMAP')
      umap_run.reload
      unless run_success?(umap_run)
        return Result.new(
          skipped: false,
          pca_run: pca_run,
          umap_run: umap_run,
          error: @error || "UMAP run #{umap_run.id} did not succeed"
        )
      end
    end

    Result.new(skipped: false, pca_run: pca_run, umap_run: umap_run)
  rescue StandardError => e
    @logger.error("[SpatialUmapEnsureService] project=#{@project.key} #{e.class}: #{e.message}")
    Result.new(skipped: false, error: e.message)
  end

  def start_umap_after_pca(pca_run)
    return nil unless spatial_dataset?
    return nil if umap_exists?

    pca_annot = pca_output_annot(pca_run)
    if pca_annot.nil?
      @logger.info("[SpatialUmapEnsureService] no PCA annot yet for run=#{pca_run.id} project=#{@project.key}")
      return nil
    end

    existing = find_umap_run(pca_annot)
    if existing
      exec_if_waiting(existing)
      return existing
    end

    start_run!(
      step_name: UMAP_STEP_NAME,
      std_method_name: UMAP_STD_METHOD_NAME,
      input_annot: pca_annot,
      extra_attrs: {
        'nber_pcs' => NBER_DIMS,
        'n_components' => 2,
        'n_neighbors' => 15,
        'metric' => 'euclidean',
        'min_dist' => 0.5,
        'random_state' => 42
      }
    )
  end

  private

  def spatial_dataset?
    return true if @project.project_type&.tag.to_s == 'spat'

    @project.inferred_project_type_tag_from_assay == 'spat'
  end

  def umap_exists?
    embedding_annots.any? { |annot| annot.name.to_s.match?(UMAP_NAME) }
  end

  def embedding_annots
    Annot.where(project_id: @project.id, dim: 1, nber_rows: 2).where.not(filepath: nil)
  end

  def matrix_annot
    Annot.where(project_id: @project.id, name: '/matrix', dim: 3)
         .where.not(filepath: nil)
         .order(id: :desc)
         .first
  end

  def ensure_pca_run!(matrix)
    existing = find_pca_run(matrix)
    if existing
      exec_if_waiting(existing)
      return existing
    end

    start_run!(
      step_name: PCA_STEP_NAME,
      std_method_name: PCA_STD_METHOD_NAME,
      input_annot: matrix,
      extra_attrs: {
        'nber_dims' => NBER_DIMS,
        'svd_solver' => 'arpack',
        'random_state' => 42,
        'no_zero_center' => false,
        'chunked' => false
      }
    )
  end

  def find_pca_run(matrix)
    find_auto_run(PCA_STEP_NAME, matrix)
  end

  def find_umap_run(pca_annot)
    find_auto_run(UMAP_STEP_NAME, pca_annot)
  end

  def find_auto_run(step_name, input_annot)
    step = step_for(step_name)
    return nil unless step

    Run.where(project_id: @project.id, step_id: step.id)
       .where.not(status_id: [4, 5])
       .order(id: :desc)
       .find { |run| auto_run_for_annot?(run, input_annot) }
  end

  def auto_run_for_annot?(run, input_annot)
    attrs = Basic.safe_parse_json(run.attrs_json, {})
    return false unless attrs[AUTO_ATTR]

    input = attrs['input_matrix']
    return false unless input.is_a?(Hash)

    input['annot_id'].to_i == input_annot.id
  end

  def pca_output_annot(pca_run)
    Annot.where(run_id: pca_run.id, dim: 1)
         .where('nber_rows >= 2')
         .order(id: :desc)
         .find { |annot| annot.name.to_s.match?(PCA_NAME) }
  end

  def start_run!(step_name:, std_method_name:, input_annot:, extra_attrs:)
    step = step_for(step_name)
    std_method = std_method_for(step, std_method_name)
    if step.nil? || std_method.nil?
      @error = "#{step_name}/#{std_method_name} is not configured for this project version"
      @logger.error("[SpatialUmapEnsureService] #{@error} project=#{@project.key}")
      return nil
    end
    if input_annot.run_id.blank?
      @error = "#{input_annot.name} has no run_id"
      return nil
    end

    version = @project.version
    docker_image = Basic.get_asap_docker(version)
    h_env = Basic.safe_parse_json(version&.env_json, {})
    if docker_image.nil? || h_env.blank?
      @error = 'Project version docker image is missing'
      return nil
    end

    ProjectStep.find_or_create_by!(project_id: @project.id, step_id: step.id) do |ps|
      ps.status_id = 1
    end

    h_cmd_params = Basic.safe_parse_json(step.command_json, {})
    tmp_h = Basic.safe_parse_json(std_method.command_json, {})
    tmp_h.each_key { |k| h_cmd_params[k] = tmp_h[k] }

    h_attrs = extra_attrs.merge(
      AUTO_ATTR => true,
      'input_matrix' => {
        'annot_id' => input_annot.id,
        'run_id' => input_annot.run_id
      }
    )

    last_run = Run.where(project_id: @project.id, step_id: step.id).order(id: :desc).first
    run = Run.create!(
      project_id: @project.id,
      step_id: step.id,
      std_method_id: std_method.id,
      status_id: 6,
      num: last_run ? last_run.num + 1 : 1,
      user_id: @user_id,
      async: true,
      command_json: '{}',
      attrs_json: h_attrs.to_json,
      run_parents_json: '[]',
      output_json: '{}',
      lineage_run_ids: '',
      submitted_at: Time.now
    )

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    FileUtils.mkdir_p(project_dir)
    step_dir = project_dir + step.name
    FileUtils.mkdir_p(step_dir)
    output_dir = step_dir + run.id.to_s
    FileUtils.rm_r(output_dir) if File.exist?(output_dir)
    Dir.mkdir(output_dir)

    h_data_classes = {}
    DataClass.all.each { |dc| h_data_classes[dc.id] = dc }
    h_res_attrs = Basic.get_std_method_attrs(std_method, step)

    h_p = {
      project: @project,
      h_cmd_params: h_cmd_params,
      run: run,
      p: h_attrs,
      h_attrs: h_res_attrs[:h_attrs],
      step: step,
      h_data_classes: h_data_classes,
      std_method: std_method,
      h_env: h_env,
      h_annots: { input_annot.id => input_annot },
      el_time: Time.now,
      user_id: @user_id
    }
    set_res = Basic.set_run(@logger, h_p)
    if set_res.is_a?(Hash) && set_res[:error].present?
      run.update(status_id: 4, error: set_res[:error].to_s)
      @error = set_res[:error].to_s
      return run
    end

    run.reload
    Basic.exec_run(@logger, run)
    run.reload
    @logger.info(
      "[SpatialUmapEnsureService] started #{step_name}/#{std_method_name} Run##{run.id} " \
      "project=#{@project.key} input=#{input_annot.name}"
    )
    run
  end

  def exec_if_waiting(run)
    return unless [1, 6].include?(run.status_id.to_i)

    Basic.exec_run(@logger, run)
    run.reload
  end

  def wait_for_run!(run, label)
    deadline = Time.now + @timeout_sec
    loop do
      run.reload
      return if run_success?(run)
      if [4, 5].include?(run.status_id.to_i)
        @error = "#{label} run #{run.id} failed (status_id=#{run.status_id})"
        return
      end
      if Time.now > deadline
        @error = "#{label} run #{run.id} timed out after #{@timeout_sec}s"
        return
      end
      @logger.info(
        "[SpatialUmapEnsureService] waiting for #{label} project=#{@project.key} " \
        "run=#{run.id} status_id=#{run.status_id}"
      )
      sleep POLL_INTERVAL_SEC
    end
  end

  def run_success?(run)
    run.status_id.to_i == 3
  end

  def step_for(name)
    docker_image = Basic.get_asap_docker(@project.version)
    return nil unless docker_image

    Step.find_by(name: name, docker_image_id: docker_image.id, version_id: @project.version_id)
  end

  def std_method_for(step, name)
    return nil unless step

    StdMethod.find_by(name: name, step_id: step.id, obsolete: false) ||
      StdMethod.find_by(name: name, step_id: step.id)
  end
end
