desc '####################### Build prediction model'
task build_pred_models: :environment do
  puts 'Executing...'

  data_root = Basic.prediction_data_root_mount
  models_root = Basic.prediction_models_path_for_r
  run_stats_root = File.join(data_root, 'run_stats')
  vol = Basic.prediction_docker_volume_mount_arg

  FileUtils.mkdir_p(run_stats_root)
  FileUtils.mkdir_p(models_root)

  Version.all.select { |v| v.id > 4 }.each do |v|
    asap_docker_image = Basic.get_asap_docker(v)
    unless asap_docker_image
      puts "Version #{v.id}: no asap_run docker image, skipping"
      next
    end

    puts "Version #{v.id}..."
    list = Basic.get_run_stats(v)
    output_file = File.join(run_stats_root, "#{v.id}.json")
    File.write(output_file, list.to_json)

    version_models_dir = File.join(models_root, v.id.to_s)
    FileUtils.mkdir_p(version_models_dir)

    # Do not mount over /srv: prediction.tool.2.R ships in the asap_run image WORKDIR (/srv).
    cmd_str = "docker run --entrypoint '/bin/sh' --rm #{vol} fabdavid/asap_run:#{asap_docker_image.tag} -c \"Rscript prediction.tool.2.R build #{version_models_dir} #{output_file}\""
    puts cmd_str
    system(cmd_str) || raise("build_pred_models failed for version #{v.id}")
  end
end
