class SelectionMetadataImportJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = Run.find_by(id: run_id)
    return unless run

    project = run.project
    step = run.step
    return unless project && step

    attrs = Basic.safe_parse_json(run.attrs_json, {})
    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key

    run.update(
      status_id: 2,
      start_time: Time.now,
      waiting_duration: run.submitted_at ? (Time.now - run.submitted_at).to_f : nil
    )
    Basic.upd_project_step(project, step.id)
    project.broadcast(step.id) if project.respond_to?(:broadcast)

    loom_file = attrs['loom_file'].to_s
    metadata_name = attrs['selection_metadata_name'].to_s
    selected_file = attrs['selected_cells_file'].to_s
    selected_name = attrs['selected_name'].presence || 'Selected'
    unselected_name = attrs['unselected_name'].presence || 'Not selected'

    if loom_file.blank? || metadata_name.blank? || selected_file.blank?
      raise StandardError, 'Missing selection metadata parameters'
    end
    broadcast_selection_states_changed(project, loom_file: loom_file, status: 'running', run_id: run.id)

    loom_path = project_dir + loom_file
    unless File.exist?(loom_path)
      raise StandardError, "Loom file not found: #{loom_file}"
    end

    selected_file_path = Pathname.new(selected_file)
    unless File.exist?(selected_file_path)
      raise StandardError, 'Selection cells file not found'
    end

    meta = H5DataService.write_cell_selection!(loom_path.to_s, metadata_name, selected_file_path.to_s)
    if meta.blank? || meta['name'].blank?
      raise StandardError, 'Cell selection write returned empty metadata'
    end

    meta['data_class_names'] = ['dataset', 'mdata', 'col_mdata', 'discrete_mdata']
    h_data_types = {}
    DataType.all.each { |dt| h_data_types[dt.name] = dt }
    h_data_classes = {}
    DataClass.all.each { |dc| h_data_classes[dc.name] = dc }

    new_annot = Basic.load_annot(run, meta, loom_file, h_data_types, h_data_classes, Rails.logger)
    raise StandardError, 'Selection metadata annotation not created' unless new_annot

    new_annot.update(
      cat_aliases_json: {
        user_ids: { '0' => run.user_id, '1' => run.user_id },
        names: { '0' => unselected_name, '1' => selected_name }
      }.to_json,
      attrs_json: {
        selection_source: attrs['selection_source'],
        plot_context: attrs['plot_context'],
        heatmap_run_id: attrs['heatmap_run_id'],
        compose_steps: attrs['compose_steps'],
        filter_components: attrs['filter_components']
      }.compact.to_json
    )

    [['0', unselected_name], ['1', selected_name]].each do |cat, label|
      cla = Cla.where(project_id: project.id, annot_id: new_annot.id, cat: cat, name: label, user_id: run.user_id).first
      next if cla
      Cla.create(project_id: project.id, annot_id: new_annot.id, cat: cat, name: label, user_id: run.user_id)
    end

    run.update(
      status_id: 3,
      duration: run.start_time ? (Time.now - run.start_time).to_f : nil
    )
    Basic.upd_project_step(project, step.id)
    project.broadcast(step.id) if project.respond_to?(:broadcast)
    broadcast_selection_states_changed(project, loom_file: loom_file, status: 'completed', run_id: run.id)
  rescue StandardError => e
    Rails.logger.error("[SelectionMetadataImportJob] Run##{run_id} failed: #{e.class} - #{e.message}")
    if run
      run.update(status_id: 4, error: e.message)
      if project && step
        Basic.upd_project_step(project, step.id)
        project.broadcast(step.id) if project.respond_to?(:broadcast)
      end
      failure_attrs = Basic.safe_parse_json(run.attrs_json, {})
      broadcast_selection_states_changed(project, loom_file: failure_attrs['loom_file'], status: 'failed', run_id: run.id) if project
    end
  end

  private

  def broadcast_selection_states_changed(project, loom_file:, status:, run_id:)
    return unless project&.id

    ActionCable.server.broadcast(
      "project_#{project.id}",
      {
        event: 'selection_states_changed',
        loom_file: loom_file.to_s,
        status: status.to_s,
        run_id: run_id.to_i
      }
    )
  rescue StandardError => e
    Rails.logger.warn("[SelectionMetadataImportJob] selection websocket broadcast failed for run##{run_id}: #{e.class} - #{e.message}")
  end
end
