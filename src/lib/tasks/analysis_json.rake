# frozen_string_literal: true

namespace :analysis_json do
  desc 'Create or update /attrs/analysis_pipeline on a project loom from DB runs. ' \
       'Usage: rake analysis_json:update[PROJECT_KEY,parsing/output.loom] ' \
       'or ANALYSIS_JSON_PROJECT_KEY=... ANALYSIS_JSON_LOOM_FILE=... rake analysis_json:update'
  task :update, [:project_key, :loom_filepath] => :environment do |_t, args|
    project_key = args[:project_key].presence || ENV['ANALYSIS_JSON_PROJECT_KEY'].presence || ENV['PROJECT_KEY'].presence
    loom_filepath = args[:loom_filepath].presence || ENV['ANALYSIS_JSON_LOOM_FILE'].presence || ENV['LOOM_FILE'].presence
    abort('project_key is required') if project_key.blank?
    abort('loom_filepath is required') if loom_filepath.blank?

    project = Project.find_by(key: project_key)
    abort("Project not found: #{project_key}") unless project

    result = AnalysisJsonPersistService.call(project: project, loom_filepath: loom_filepath)
    puts "Updated #{result[:attr_path]} on #{result[:loom_filepath]} " \
         "(annot_id=#{result[:annot_id]}, steps=#{result[:nber_steps]}, bytes=#{result[:bytes]})"
  end

  desc 'Create or update /attrs/analysis_pipeline on every distinct loom filepath of a project. ' \
       'Usage: rake analysis_json:update_project[PROJECT_KEY]'
  task :update_project, [:project_key] => :environment do |_t, args|
    project_key = args[:project_key].presence || ENV['ANALYSIS_JSON_PROJECT_KEY'].presence || ENV['PROJECT_KEY'].presence
    abort('project_key is required') if project_key.blank?

    project = Project.find_by(key: project_key)
    abort("Project not found: #{project_key}") unless project

    loom_files = Annot.where(project_id: project.id)
                      .where('filepath LIKE ?', '%.loom')
                      .distinct
                      .pluck(:filepath)
                      .compact
                      .sort
    abort("No loom filepaths found for project #{project_key}") if loom_files.empty?

    loom_files.each do |loom_filepath|
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      loom_path = project_dir + loom_filepath
      unless File.exist?(loom_path)
        puts "SKIP missing file: #{loom_filepath}"
        next
      end

      result = AnalysisJsonPersistService.call(project: project, loom_filepath: loom_filepath)
      puts "Updated #{result[:loom_filepath]} annot_id=#{result[:annot_id]} steps=#{result[:nber_steps]}"
    end
  end
end
