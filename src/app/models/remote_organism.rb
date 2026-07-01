class RemoteOrganism < Asap2RemoteRecord
  self.table_name = "organisms"

  DISPLAY_ATTRIBUTES = %w[id name short_name tax_id ensembl_subdomain_id created_at updated_at].freeze

  TARGET_LATEST_RELEASE_SQL = <<~SQL.squish
    COALESCE(
      NULLIF(ensembl_subdomains.latest_ensembl_release, 0),
      NULLIF(organisms.latest_ensembl_release, 0),
      0
    )
  SQL

  def self.list_for_version(version)
    with_remote(version) do
      assembly_flag_sql = assembly_at_latest_release_exists_sql
      joins('LEFT JOIN ensembl_subdomains ON organisms.ensembl_subdomain_id = ensembl_subdomains.id')
        .select("organisms.*, ensembl_subdomains.name as domain_name, (#{assembly_flag_sql}) AS assembly_at_latest_release")
        .order(:name)
        .map do |organism|
          attrs = organism.attributes.slice(*DISPLAY_ATTRIBUTES)
          attrs['domain_name'] = organism.read_attribute('domain_name')
          attrs['assembly_at_latest_release'] = ActiveRecord::Type::Boolean.new.cast(
            organism.read_attribute('assembly_at_latest_release')
          )
          attrs
        end
    end
  end

  def self.assembly_at_latest_release_exists_sql
    release_sql = TARGET_LATEST_RELEASE_SQL
    <<~SQL.squish
      EXISTS (
        SELECT 1
        FROM assemblies
        WHERE assemblies.organism_id = organisms.id
          AND #{release_sql} > 0
          AND (assemblies.first_ensembl_release IS NULL OR assemblies.first_ensembl_release <= #{release_sql})
          AND (assemblies.latest_ensembl_release IS NULL OR assemblies.latest_ensembl_release >= #{release_sql})
      )
    SQL
  end
  private_class_method :assembly_at_latest_release_exists_sql
end

