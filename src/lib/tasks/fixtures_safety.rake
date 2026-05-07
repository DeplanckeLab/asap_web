namespace :safety do
  def ensure_not_production_db!(task_name:, override_env:)
    return unless Rails.env.production?

    db_name = ActiveRecord::Base.connection_db_config&.database.to_s
    allow_override = ENV[override_env] == "1"

    return if allow_override

    abort(
      "[SAFETY] Refusing to run #{task_name} in production " \
      "(database='#{db_name}'). Set #{override_env}=1 to override intentionally."
    )
  end

  desc "Prevent fixtures load on production DB unless explicitly allowed"
  task :prevent_production_fixtures_load => :environment do
    ensure_not_production_db!(
      task_name: "db:fixtures:load",
      override_env: "ALLOW_PRODUCTION_FIXTURES_LOAD"
    )
  end

  desc "Prevent db:seed on production DB unless explicitly allowed"
  task :prevent_production_seed => :environment do
    ensure_not_production_db!(
      task_name: "db:seed",
      override_env: "ALLOW_PRODUCTION_DB_SEED"
    )
  end

  desc "Prevent db:schema:load on production DB unless explicitly allowed"
  task :prevent_production_schema_load => :environment do
    ensure_not_production_db!(
      task_name: "db:schema:load",
      override_env: "ALLOW_PRODUCTION_SCHEMA_LOAD"
    )
  end

  desc "Prevent db:reset on production DB unless explicitly allowed"
  task :prevent_production_db_reset => :environment do
    ensure_not_production_db!(
      task_name: "db:reset",
      override_env: "ALLOW_PRODUCTION_DB_RESET"
    )
  end

  desc "Prevent db:setup on production DB unless explicitly allowed"
  task :prevent_production_db_setup => :environment do
    ensure_not_production_db!(
      task_name: "db:setup",
      override_env: "ALLOW_PRODUCTION_DB_SETUP"
    )
  end
end

Rake::Task["db:fixtures:load"].enhance(["safety:prevent_production_fixtures_load"])
Rake::Task["db:seed"].enhance(["safety:prevent_production_seed"]) if Rake::Task.task_defined?("db:seed")
Rake::Task["db:schema:load"].enhance(["safety:prevent_production_schema_load"]) if Rake::Task.task_defined?("db:schema:load")
Rake::Task["db:reset"].enhance(["safety:prevent_production_db_reset"]) if Rake::Task.task_defined?("db:reset")
Rake::Task["db:setup"].enhance(["safety:prevent_production_db_setup"]) if Rake::Task.task_defined?("db:setup")
