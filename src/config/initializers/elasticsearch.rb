# Elasticsearch configuration
Elasticsearch::Model.client = Elasticsearch::Client.new(
  host: ENV['ELASTICSEARCH_URL'] || 'localhost:9200',
  log: Rails.env.development?,
  retry_on_failure: 3,
  reload_connections: true,
  randomize_hosts: true,
  transport_options: {
    request: { timeout: 5 }
  }
)

# Create indices if they don't exist (moved to rake task)
Rails.application.config.after_initialize do
  if Rails.env.development? || Rails.env.test?
    begin
      if defined?(Project) && Project.respond_to?(:__elasticsearch__)
        Project.__elasticsearch__.create_index!(force: true) unless Project.__elasticsearch__.index_exists?
      end
    rescue => e
      Rails.logger.warn "Could not initialize Elasticsearch index: #{e.message}"
    end
  end
end
