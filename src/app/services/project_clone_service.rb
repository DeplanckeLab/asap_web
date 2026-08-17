# frozen_string_literal: true

# Service for cloning projects and all associated data
# Creates a complete copy of a project including runs, annots, files, etc.
class ProjectCloneService
  attr_reader :source_project, :user, :session, :new_project, :errors

  def initialize(source_project, user:, session:, admin: false)
    @source_project = source_project
    @user = user
    @session = session
    @admin = admin
    @errors = []
    @h_runs = {}
    @h_annots = {}
  end

  # Persist the destination project so a compose restart can resume the copy.
  def start!
    return nil unless can_clone?

    create_new_project
    @new_project.update_column(:being_cloned, true)
    update_source_clone_count
    @new_project
  rescue StandardError => e
    @errors << e.message
    Rails.logger.error "Project clone start failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    cleanup_failed_clone
    nil
  end

  def complete_existing!(dest_project)
    @new_project = dest_project
    complete!
  end

  def complete!
    raise ArgumentError, 'Destination project is missing' unless @new_project
    raise ArgumentError, "Project##{@new_project.id} is not being cloned" unless @new_project.being_cloned

    reset_partial_clone!
    create_project_directory
    copy_runs
    copy_fos
    copy_annots
    copy_annot_cell_sets
    update_run_references
    copy_project_steps
    copy_associations
    rename_run_folders
    @new_project.update_column(:being_cloned, false)
    @new_project
  end

  # Clone the project and return the new project or nil on failure
  def call
    return nil unless start!

    complete!
    new_project
  rescue StandardError => e
    @errors << e.message
    Rails.logger.error "Project clone failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    cleanup_failed_clone
    nil
  end

  private

  def can_clone?
    source_project.present?
  end

  def create_new_project
    @new_project = source_project.dup
    
    if user
      @new_project.sandbox = false
    else
      @new_project.sandbox = true
    end

    @new_project.key = Project.generate_unique_key
    session[:sandbox] = @new_project.key if user.nil?
    
    now = Time.current
    
    @new_project.assign_attributes(
      name: next_clone_name,
      public: false,
      user_id: user&.id || 1,
      cloned_project_id: source_project.id,
      root_project_id: Project.root_project_id_for_clone_source(source_project),
      nber_views: 0,
      nber_cloned: 0,
      last_day_session_ids: '',
      parsing_job_id: nil,
      filtering_job_id: nil,
      normalization_job_id: nil,
      replaced_by_project_key: nil,
      replaced_by_comment: nil,
      # Clones get a local file copy; never inherit the source's S3 archive bookkeeping
      # (dup would keep archive_status_id=3 / disk_size_archived and the UI would try to
      # unarchive under the new key, which does not exist on S3).
      archive_status_id: 1,
      disk_size_archive: nil,
      disk_size_archived: nil,
      being_cloned: true,
      viewed_at: now,
      created_at: now,
      updated_at: now,
      modified_at: now,
      frozen_at: nil,
      public_at: nil,
      public_id: nil,
      landing_page_json: '{}',
      project_origin_id: ProjectOrigin.id_for(ProjectOrigin::CLONE)
    )
    
    @new_project.save!
  end

  def next_clone_name
    name = source_project.name
    repeated = name.scan(/ cloned(?!\s*\[)/).length
    base = name.sub(/( cloned)+(?:\s*\[\d+\])?$/, '')
    owner_id = user&.id || 1
    existing_nums = Project.where(user_id: owner_id)
                           .where("name LIKE ?", "#{Project.sanitize_sql_like(base)} cloned%")
                           .pluck(:name)
                           .filter_map { |n| n[/cloned\s*\[(\d+)\]$/, 1]&.to_i }
    max_num = ([repeated] + existing_nums).max || 0
    "#{base} cloned [#{max_num + 1}]"
  end

  def create_project_directory
    new_user_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + (new_project.user_id&.to_s || '0')
    FileUtils.mkdir_p(new_user_dir) unless File.exist?(new_user_dir)
    
    @new_project_dir = new_user_dir + new_project.key
    @source_project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + source_project.user_id.to_s + source_project.key
    
    # Unarchive source if needed
    if source_project.archive_status_id == 3
      unless Basic.unarchive(source_project.key)
        raise "Could not unarchive source project #{source_project.key} before cloning"
      end
    end
    
    # Copy directory if they're different
    if @source_project_dir != @new_project_dir
      # If the destination already exists, cp_r nests src inside it (e.g. new_key/old_key/...),
      # which breaks layout and can raise Errno::EEXIST. Remove stale dirs from failed clones.
      FileUtils.rm_rf(@new_project_dir) if File.exist?(@new_project_dir)
      FileUtils.cp_r(@source_project_dir, @new_project_dir)
    end
  end

  def copy_runs
    source_project.runs.order(:id).each do |run|
      new_run = run.dup
      new_run.project_id = new_project.id
      new_run.save!
      @h_runs[run.id] = new_run
    end
  end

  def copy_fos
    Fo.where(project_id: source_project.id).find_each do |fo|
      new_fo = fo.dup
      new_fo.filepath = fo.filepath.gsub(/#{fo.run_id}/, @h_runs[fo.run_id].id.to_s) if fo.filepath && @h_runs[fo.run_id]
      new_fo.run_id = @h_runs[fo.run_id]&.id
      new_fo.project_id = new_project.id
      new_fo.save!
    end
  end

  def copy_annots
    source_project.annots.order(:id).each do |annot|
      new_annot = annot.dup
      new_annot.project_id = new_project.id
      new_annot.run_id = @h_runs[annot.run_id]&.id if annot.run_id
      
      if annot.filepath && annot.store_run_id && @h_runs[annot.store_run_id]
        new_annot.filepath = annot.filepath.gsub(/#{annot.store_run_id}/, @h_runs[annot.store_run_id].id.to_s)
      end
      
      new_annot.store_run_id = @h_runs[annot.store_run_id]&.id if annot.store_run_id
      new_annot.ori_run_id = @h_runs[annot.ori_run_id]&.id if annot.ori_run_id
      new_annot.save!
      @h_annots[annot.id] = new_annot
    end
  end

  def copy_annot_cell_sets
    AnnotCellSet.where(project_id: source_project.id).find_each do |acs|
      new_acs = acs.dup
      new_acs.project_id = new_project.id
      new_acs.annot_id = @h_annots[acs.annot_id]&.id if acs.annot_id
      new_acs.save!
    end
  end

  def update_run_references
    h_steps = build_steps_hash
    
    source_project.runs.each do |run|
      new_run = @h_runs[run.id]
      next unless new_run
      
      step = h_steps[run.step_id]
      next unless step
      
      run_dir = @source_project_dir + step.name
      new_run_dir = @new_project_dir + step.name
      
      if step.multiple_runs
        run_dir = @source_project_dir + step.name + run.id.to_s
        new_run_dir = @new_project_dir + step.name + new_run.id.to_s
        output_file = @new_project_dir + step.name + run.id.to_s + "output.log"
      else
        output_file = @new_project_dir + step.name + "output.log"
      end
      
      # Delete output.log as it contains paths that are hard to update
      FileUtils.rm_f(output_file) if File.exist?(output_file)
      
      # Update output_json
      new_h_output = update_output_json(run)
      
      # Update lineage and parent references
      new_lineage_run_ids = run.lineage_run_ids.to_s.split(",").select { |id| @h_runs[id.to_i] }.map { |id| @h_runs[id.to_i].id }
      new_children_run_ids = run.children_run_ids.to_s.split(",").map { |id| @h_runs[id.to_i]&.id }.compact
      
      new_parent_run = update_parent_run_json(run)
      new_command = update_command_json(run, run_dir, new_run_dir)
      new_attrs = update_attrs_json(run)
      
      new_run.update!(
        attrs_json: new_attrs.to_json,
        command_json: new_command.to_json,
        output_json: new_h_output.to_json,
        lineage_run_ids: new_lineage_run_ids.join(","),
        run_parents_json: new_parent_run.to_json,
        children_run_ids: new_children_run_ids.join(","),
        cloned_run_id: run.id
      )
    end
  end

  def build_steps_hash
    asap_docker_image = Basic.get_asap_docker(source_project.version)
    return {} unless asap_docker_image
    
    Step.where(docker_image_id: asap_docker_image.id).index_by(&:id)
  end

  def update_output_json(run)
    h_output = Basic.safe_parse_json(run.output_json, {})
    new_h_output = {}
    
    h_output.each do |k, v|
      new_h_output[k] = {}
      v.each do |k2, v2|
        l = k2.split(":")
        t = l[0].split("/")
        
        if t.size == 3 && (run_id = t[1]) && @h_runs[run_id.to_i]
          t[1] = @h_runs[run_id.to_i].id
          l[0] = t.join("/")
          new_k2 = l.join(":")
          new_h_output[k][new_k2] = v2.dup
        elsif t.size == 2
          new_h_output[k][k2] = v2.dup
        end
      end
    end
    
    new_h_output
  end

  def update_parent_run_json(run)
    return [] unless run.run_parents_json
    
    parent_runs = Basic.safe_parse_json(run.run_parents_json, [])
    return [] unless parent_runs.is_a?(Array) && parent_runs.any?
    
    parent_runs.map do |p_run|
      {
        run_id: @h_runs[p_run["run_id"]]&.id,
        type: p_run["type"],
        output_attr_name: p_run["output_attr_name"]
      }
    end
  end

  def update_command_json(run, run_dir, new_run_dir)
    new_command = Basic.safe_parse_json(run.command_json, {})
    
    if new_command['container_name']
      parts = new_command['container_name'].split("_").map { |e| @h_runs[e.to_i]&.id || e }
      new_command['container_name'] = parts.join("_")
    end
    
    if new_command['program']
      new_command['program'] = new_command['program'].gsub(/\[#{source_project.key}\]/, "[#{new_project.key}]")
    end
    
    # Update path references in various command fields
    ['time_call', 'exec_stdout', 'exec_stderr'].each do |k|
      next unless new_command[k]
      new_command[k] = replace_path_references(new_command[k].to_s)
    end
    
    ['args', 'opts'].each do |k|
      next unless new_command[k]
      new_command[k].each_with_index do |arg, i|
        if arg['value']
          new_command[k][i]['value'] = replace_path_references(arg['value'].to_s)
        end
      end
    end

    if new_command['db_json'].is_a?(Hash) && new_command['db_json']['annot_ids'].is_a?(Array)
      old_ids = new_command['db_json']['annot_ids']
      new_ids = old_ids.map { |aid| @h_annots[aid.to_i]&.id }.compact.uniq
      new_command['db_json'] = new_command['db_json'].merge('annot_ids' => new_ids)
    end

    new_command
  end

  def update_attrs_json(run)
    new_attrs = Basic.safe_parse_json(run.attrs_json, {})
    
    new_attrs.each do |k, v|
      if v.is_a?(Hash)
        new_attrs[k] = clone_replace_attr(v)
      elsif v.is_a?(Array)
        new_attrs[k] = v.map { |item| item.is_a?(Hash) ? clone_replace_attr(item) : item }
      else
        new_attrs[k] = replace_path_references(v.to_s)
      end
    end
    
    new_attrs
  end

  def clone_replace_attr(attr)
    attr.each do |k, v|
      case k
      when 'run_id'
        attr['run_id'] = @h_runs[attr['run_id'].to_i]&.id
      when 'annot_id'
        attr['annot_id'] = @h_annots[attr['annot_id'].to_i]&.id
      else
        if v.is_a?(String)
          attr[k] = replace_path_references(v)
        end
      end
    end
    attr
  end

  def replace_path_references(value)
    return value unless value.is_a?(String)
    
    # Match pattern: /user_id/project_key/step_name/run_id/
    if (match = value.match(%r{/(\d+)/#{source_project.key}/\w+?/(\d+)/?}))
      user_id = match[1]
      run_id = match[2]
      
      if @h_runs[run_id.to_i]
        value = value.gsub(%r{/#{run_id}/}, "/#{@h_runs[run_id.to_i].id}/")
        value = value.gsub(%r{/#{run_id}$}, "/#{@h_runs[run_id.to_i].id}")
        value = value.gsub(%r{/#{source_project.key}/}, "/#{new_project.key}/")
        value = value.gsub(%r{/#{user_id}/}, "/#{new_project.user_id}/") if new_project.user_id
      end
    end
    
    value
  end

  def copy_project_steps
    source_project.project_steps.order(:updated_at).each do |ps|
      new_ps = ps.dup
      new_ps.project_id = new_project.id
      new_ps.save!
    end
  end

  def copy_associations
    # Copy exp_entries association
    source_project.exp_entries.each do |entry|
      new_project.exp_entries << entry unless new_project.exp_entries.include?(entry)
    end
    
    # Copy provider_projects association
    source_project.provider_projects.each do |pp|
      new_project.provider_projects << pp unless new_project.provider_projects.include?(pp)
    end
  end

  def rename_run_folders
    asap_docker_image = Basic.get_asap_docker(source_project.version)
    return unless asap_docker_image
    
    Step.where(docker_image_id: asap_docker_image.id, multiple_runs: true).find_each do |step|
      Run.where(project_id: source_project.id, step_id: step.id).find_each do |run|
        old_run_dir = @new_project_dir + step.name + run.id.to_s
        new_run_dir = @new_project_dir + step.name + @h_runs[run.id].id.to_s
        
        if File.exist?(old_run_dir) && !File.exist?(new_run_dir)
          FileUtils.mv(old_run_dir, new_run_dir)
        end
      end
    end
  end

  def update_source_clone_count
    current_count = source_project.nber_cloned || 0
    source_project.update_column(:nber_cloned, current_count + 1) unless @admin
  end

  def reset_partial_clone!
    return unless @new_project&.persisted?

    new_user_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + (@new_project.user_id&.to_s || '0')
    @new_project_dir = new_user_dir + @new_project.key
    FileUtils.rm_rf(@new_project_dir) if File.exist?(@new_project_dir)

    Fo.where(project_id: @new_project.id).find_each(&:destroy)
    AnnotCellSet.where(project_id: @new_project.id).find_each(&:destroy)
    @new_project.annots.find_each(&:destroy)
    @new_project.runs.find_each(&:destroy)
    @new_project.project_steps.find_each(&:destroy)
    @new_project.exp_entries.clear
    @new_project.provider_projects.clear
    @h_runs = {}
    @h_annots = {}
  end

  def cleanup_failed_clone
    return unless @new_project&.persisted?

    begin
      decrement_source_clone_count
      if @new_project_dir && File.exist?(@new_project_dir)
        FileUtils.rm_rf(@new_project_dir)
      end

      @new_project.destroy
      @new_project = nil
    rescue StandardError => e
      Rails.logger.error "Failed to cleanup after failed clone: #{e.message}"
    end
  end

  def decrement_source_clone_count
    return if @admin
    return unless source_project

    current_count = source_project.nber_cloned.to_i
    return if current_count <= 0

    source_project.update_column(:nber_cloned, current_count - 1)
  end
end
