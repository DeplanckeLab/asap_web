require 'shellwords'

desc 'Parse metadata import (executed by SLURM via website container)'
task :parse_metadata, [:run_id] => [:environment] do |_t, args|
  puts 'Executing parse_metadata...'

  write_error = lambda do |output_dir, message|
    FileUtils.mkdir_p(output_dir)
    File.open(Pathname.new(output_dir) + 'output.json', 'w') do |f|
      f.write({ 'displayed_error' => [message.to_s] }.to_json)
    end
  end

  logger = Logger.new(Rails.root.join('log', 'exec_run.log'))
  logger.level = Logger::INFO
  run_id = args[:run_id]
  puts "run_id=#{run_id}"

  run = Run.find_by(id: run_id)
  abort("[ParseMetadata] Run #{run_id} not found") unless run

  project = run.project
  version = project.version
  asap_docker_image = Basic.get_asap_docker(version)
  abort("[ParseMetadata] ASAP docker image not found for project #{project.key}") unless asap_docker_image

  project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
  step = run.step
  step_dir = project_dir + step.name
  FileUtils.mkdir_p(step_dir)
  output_dir = Basic.run_output_dir(run)
  FileUtils.mkdir_p(output_dir)

  tmp_dir = project_dir + 'tmp'
  FileUtils.mkdir_p(tmp_dir)

  start_time = Time.now
  waiting_duration = run.submitted_at ? (start_time - run.submitted_at).to_f : nil
  if run.status_id == 1 || !run.start_time
    run.update(
      status_id: 2,
      start_time: start_time,
      waiting_duration: waiting_duration
    )
  end
  Basic.upd_project_step(project, step.id)
  project_step = ProjectStep.find_by(project_id: project.id, step_id: step.id)
  project_step.update(status_id: 2) if project_step && project_step.status_id != 2
  project.update(status_id: 2) if project.status_id != 2
  project.broadcast(step.id) if project.respond_to?(:broadcast)

  h_steps = {}
  Step.where(docker_image_id: asap_docker_image.id).find_each { |s| h_steps[s.id] = s }

  h_data_types = {}
  DataType.all.each { |dt| h_data_types[dt.name] = dt }

  h_data_classes = {}
  DataClass.all.each do |dt|
    h_data_classes[dt.name] = dt
    h_data_classes[dt.id] = dt
  end

  h_metadata_types = {
    '1' => 'CELL',
    '2' => 'GENE'
  }

  h_attrs = Basic.safe_parse_json(run.attrs_json, {})
  metadata_type_id = h_attrs['metadata_type_id'].to_s
  which = h_metadata_types[metadata_type_id]
  unless which
    write_error.call(output_dir, "Unsupported metadata_type_id=#{metadata_type_id.inspect} for parse_metadata")
    abort("[ParseMetadata] Unsupported metadata_type_id=#{metadata_type_id.inspect}")
  end

  fu = Fu.find_by(id: h_attrs['fu_id'])
  abort("[ParseMetadata] Fu #{h_attrs['fu_id']} not found") unless fu

  fu_dir = fu.upload_dir
  input_filename = h_attrs['input_filename'].presence || fu.upload_file_name
  input_filepath = fu_dir + input_filename
  unless File.exist?(input_filepath)
    write_error.call(output_dir, "Staged metadata file missing: #{input_filepath}")
    abort("[ParseMetadata] Staged metadata file missing: #{input_filepath}")
  end

  input_run_ids = h_attrs['input_run_ids'].to_s.split(',').map(&:strip).reject(&:empty?)
  matrices = Annot.where(run_id: input_run_ids, dim: 3).to_a
  parsing_mat = matrices.find { |mat| h_steps[mat.step_id]&.name == 'parsing' }
  unless parsing_mat
    write_error.call(output_dir, 'No parsing matrix found for this project')
    abort('[ParseMetadata] No parsing matrix found')
  end

  loom_relative = h_attrs['loom_file'].presence || parsing_mat.filepath
  parsing_loom_file = project_dir + loom_relative
  unless File.exist?(parsing_loom_file)
    write_error.call(output_dir, "Loom file missing: #{parsing_loom_file}")
    abort("[ParseMetadata] Loom file missing: #{parsing_loom_file}")
  end

  asap_jar = Rails.root.join('lib', 'ASAP.jar').to_s
  preparsed_json = fu_dir + 'output.json'
  preparsed_err = fu_dir + 'output.err'

  # Modern prepare_metadata only stages clipboard.txt; PreparseMetadata is required for detected_format.
  preparse_cmd = [
    'java', '-jar', asap_jar,
    '-T', 'PreparseMetadata',
    '-col', 'first',
    '-header', 'true',
    '-loom', parsing_loom_file.to_s,
    '-f', input_filepath.to_s,
    '-o', preparsed_json.to_s,
    '-which', which
  ].shelljoin + " 2> #{preparsed_err.to_s.shellescape}"
  logger.info("[ParseMetadata] PREPARSE CMD: #{preparse_cmd}")
  puts "CMD PREPARSE_METADATA: #{preparse_cmd}"
  system(preparse_cmd)
  unless File.exist?(preparsed_json)
    err = File.exist?(preparsed_err) ? File.read(preparsed_err) : 'PreparseMetadata produced no output.json'
    write_error.call(output_dir, err.to_s.strip.presence || 'PreparseMetadata failed')
    abort("[ParseMetadata] PreparseMetadata failed: #{err}")
  end

  h_res = Basic.safe_parse_json(File.read(preparsed_json), {})
  detected_format = h_res['detected_format'].to_s
  if detected_format.blank?
    write_error.call(output_dir, 'PreparseMetadata did not return detected_format')
    abort('[ParseMetadata] Missing detected_format')
  end

  options = ['-header true', '-col first']
  options.push("-metadataType #{h_attrs['metadata_types']}") if h_attrs['metadata_types'].present?
  options.push('-removeAmbiguous') if h_attrs['assign_metadata'].to_s == '0'

  output_json = output_dir + 'output.json'
  parse_cmd = [
    'java', '-jar', asap_jar,
    '-T', 'ParseMetadata',
    '-which', which,
    '-type', detected_format,
    '-loom', parsing_loom_file.to_s,
    '-f', input_filepath.to_s,
    '-o', output_json.to_s
  ].shelljoin + " #{options.join(' ')}"
  logger.info("[ParseMetadata] PARSE CMD: #{parse_cmd}")
  puts "CMD PARSE_METADATA: #{parse_cmd}"
  system(parse_cmd)

  unless File.exist?(output_json)
    write_error.call(output_dir, 'ParseMetadata produced no output.json')
    abort('[ParseMetadata] ParseMetadata produced no output.json')
  end

  h_output = Basic.safe_parse_json(File.read(output_json), {})
  displayed_error = h_output['displayed_error']
  h_output['displayed_error'] = [displayed_error] if displayed_error && !displayed_error.is_a?(Array)
  File.open(output_json, 'w') { |fw| fw.write(h_output.to_json) }

  if displayed_error.present?
    Basic.finish_run(logger, run, h_output, skip_broadcast: true)
    project.broadcast(step.id) if project.respond_to?(:broadcast)
    abort("[ParseMetadata] ParseMetadata reported error: #{displayed_error}")
  end

  outputs = []
  if (list_metadata = h_output['metadata'])
    list_metadata.each do |meta|
      meta['imported'] = true
      logger.info("[ParseMetadata] add annot #{meta.to_json}")
      Basic.load_annot(run, meta, loom_relative, h_data_types, h_data_classes, logger)
    end

    h_meta = { meta: list_metadata.map { |e| e['name'] } }
    metadata_list_file = output_dir + 'list_metadata_to_copy.json'
    File.open(metadata_list_file, 'w') { |f| f.write(h_meta.to_json) }

    other_filepaths = matrices.map(&:filepath).uniq - [loom_relative]
    other_filepaths.each do |other_rel|
      loom_to = project_dir + other_rel
      next unless File.exist?(loom_to)

      copy_cmd = [
        'java', '-jar', asap_jar,
        '-T', 'CopyMetaData',
        '-loomFrom', parsing_loom_file.to_s,
        '-loomTo', loom_to.to_s,
        '-metaJSON', metadata_list_file.to_s
      ].shelljoin
      logger.info("[ParseMetadata] COPY CMD: #{copy_cmd}")
      puts copy_cmd
      output = `#{copy_cmd}`
      puts output

      metadata_list_file2 = output_dir + "list_metadata_to_copy2_#{other_rel.to_s.gsub('/', '_')}.json"
      File.open(metadata_list_file2, 'w') { |f| f.write(output) }

      extract_cmd = [
        'java', '-jar', asap_jar,
        '-T', 'ExtractMetadata',
        '-no-values',
        '-loom', loom_to.to_s,
        '-metaJSON', metadata_list_file2.to_s
      ].shelljoin
      logger.info("[ParseMetadata] EXTRACT CMD: #{extract_cmd}")
      puts extract_cmd
      output = `#{extract_cmd}`
      outputs.push(output)
      h_extract = Basic.safe_parse_json(output, {})
      next unless (copied_metadata = h_extract['list_meta'])

      copied_metadata.each do |meta|
        meta['imported'] = true
        logger.info("[ParseMetadata] add annot #{meta.to_json}")
        Basic.load_annot(run, meta, other_rel, h_data_types, h_data_classes, logger)
      end
    end
  end

  if outputs.any?
    File.open(output_dir + 'all_outputs.json', 'w') do |fw|
      fw.write('[' + outputs.join(", \n") + ']')
    end
  end

  Basic.finish_run(logger, run, h_output, skip_broadcast: true)
  run.reload
  Basic.upd_project_step(project, step.id)
  project.update(status_id: 3) if run.status_id == 3
  project.broadcast(step.id) if project.respond_to?(:broadcast)
  logger.info("[ParseMetadata] Completed run #{run.id} status=#{run.status_id} annots=#{Annot.where(run_id: run.id).count}")
end
