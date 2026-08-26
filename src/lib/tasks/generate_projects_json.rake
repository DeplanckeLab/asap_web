# frozen_string_literal: true

desc 'Generate projects.json public catalog under DATA_DIR'
task generate_projects_json: :environment do
  puts 'Executing generate_projects_json...'

  output_path = Pathname.new(ENV.fetch('DATA_DIR')) + 'projects.json'
  public_projects = Project
                    .where(public: true, replaced_by_project_key: ['', nil])
                    .where('being_deleted IS NOT TRUE')
                    .where('version_id > 3')
                    .order(:public_id)
                    .to_a

  puts "Public projects: #{public_projects.size}"
  puts "Output: #{output_path}"

  old_logger_level = ActiveRecord::Base.logger&.level
  ActiveRecord::Base.logger.level = Logger::INFO if ActiveRecord::Base.logger

  begin
    catalog = public_projects.map { |project| Basic.generate_project_json(project) }
    tmp_path = Pathname.new("#{output_path}.tmp.#{Process.pid}")
    File.open(tmp_path, 'w') { |f| f.write(catalog.to_json) }
    File.rename(tmp_path, output_path)
    puts "Wrote #{catalog.size} projects (#{File.size(output_path)} bytes)"
  ensure
    ActiveRecord::Base.logger.level = old_logger_level if ActiveRecord::Base.logger && !old_logger_level.nil?
    tmp_path = Pathname.new("#{output_path}.tmp.#{Process.pid}")
    File.delete(tmp_path) if File.exist?(tmp_path)
  end
end
