class RemoteOrganism < Asap2RemoteRecord
  self.table_name = "organisms"

  DISPLAY_ATTRIBUTES = %w[id name short_name tax_id ensembl_subdomain_id created_at updated_at].freeze

  # Latest Ensembl release for gene mapping: organism record and gene table, not subdomain-wide.
  TARGET_LATEST_RELEASE_SQL = <<~SQL.squish
    GREATEST(
      COALESCE(NULLIF(organisms.latest_ensembl_release, 0), 0),
      COALESCE(NULLIF(gene_latest.max_gene_latest, 0), 0)
    )
  SQL

  GENE_LATEST_RELEASE_JOIN_SQL = <<~SQL.squish
    LEFT JOIN (
      SELECT organism_id, MAX(latest_ensembl_release) AS max_gene_latest
      FROM genes
      WHERE latest_ensembl_release IS NOT NULL AND latest_ensembl_release > 0
      GROUP BY organism_id
    ) gene_latest ON gene_latest.organism_id = organisms.id
  SQL

  def self.list_for_version(version)
    with_remote(version) do
      release_sql = TARGET_LATEST_RELEASE_SQL
      assembly_name_sql = assembly_name_for_target_release_sql(release_sql)
      assembly_release_sql = assembly_release_for_target_release_sql(release_sql)
      joins('LEFT JOIN ensembl_subdomains ON organisms.ensembl_subdomain_id = ensembl_subdomains.id')
        .joins(GENE_LATEST_RELEASE_JOIN_SQL)
        .select(
          'organisms.*',
          'ensembl_subdomains.name as domain_name',
          "(#{release_sql}) AS target_ensembl_release",
          "(#{assembly_name_sql}) AS assembly_name_at_latest_release",
          "(#{assembly_release_sql}) AS assembly_release_at_latest_release",
          "(#{assembly_covers_target_release_sql(release_sql)}) AS assembly_covers_target_release"
        )
        .order(:name)
        .map do |organism|
          attrs = organism.attributes.slice(*DISPLAY_ATTRIBUTES)
          attrs['domain_name'] = organism.read_attribute('domain_name')
          attrs['assembly_status'] = assembly_status_from_row(organism)
          attrs
        end
    end
  end

  def self.assembly_status_from_row(organism)
    release = organism.read_attribute('target_ensembl_release').to_i
    return nil unless release.positive?

    name = organism.read_attribute('assembly_name_at_latest_release').to_s.strip.presence
    assembly_release = organism.read_attribute('assembly_release_at_latest_release').to_i
    assembly_release = nil unless assembly_release.positive?
    present = ActiveRecord::Type::Boolean.new.cast(organism.read_attribute('assembly_covers_target_release'))
    {
      'release' => release,
      'assembly_release' => assembly_release,
      'name' => name,
      'present' => present
    }
  end

  def self.assembly_name_for_target_release_sql(release_sql)
    covering_sql = assembly_name_covering_target_release_sql(release_sql)
    fallback_sql = assembly_name_fallback_for_target_release_sql(release_sql)
    "COALESCE(#{covering_sql}, #{fallback_sql})"
  end

  def self.assembly_release_for_target_release_sql(release_sql)
    covering_sql = assembly_release_covering_target_release_sql(release_sql)
    fallback_sql = assembly_release_fallback_for_target_release_sql(release_sql)
    "COALESCE(#{covering_sql}, #{fallback_sql})"
  end

  def self.assembly_name_covering_target_release_sql(release_sql)
    <<~SQL.squish
      (
        SELECT a.name
        FROM assemblies a
        WHERE a.organism_id = organisms.id
          AND #{release_sql} > 0
          AND (a.first_ensembl_release IS NULL OR a.first_ensembl_release <= #{release_sql})
          AND (a.latest_ensembl_release IS NULL OR a.latest_ensembl_release >= #{release_sql})
        ORDER BY a.latest_ensembl_release DESC, a.name ASC
        LIMIT 1
      )
    SQL
  end

  def self.assembly_name_fallback_for_target_release_sql(release_sql)
    <<~SQL.squish
      (
        SELECT a.name
        FROM assemblies a
        WHERE a.organism_id = organisms.id
          AND #{release_sql} > 0
          AND (a.latest_ensembl_release IS NULL OR a.latest_ensembl_release <= #{release_sql})
        ORDER BY a.latest_ensembl_release DESC, a.name ASC
        LIMIT 1
      )
    SQL
  end

  def self.assembly_release_covering_target_release_sql(release_sql)
    <<~SQL.squish
      (
        SELECT a.latest_ensembl_release
        FROM assemblies a
        WHERE a.organism_id = organisms.id
          AND #{release_sql} > 0
          AND (a.first_ensembl_release IS NULL OR a.first_ensembl_release <= #{release_sql})
          AND (a.latest_ensembl_release IS NULL OR a.latest_ensembl_release >= #{release_sql})
        ORDER BY a.latest_ensembl_release DESC, a.name ASC
        LIMIT 1
      )
    SQL
  end

  def self.assembly_release_fallback_for_target_release_sql(release_sql)
    <<~SQL.squish
      (
        SELECT a.latest_ensembl_release
        FROM assemblies a
        WHERE a.organism_id = organisms.id
          AND #{release_sql} > 0
          AND (a.latest_ensembl_release IS NULL OR a.latest_ensembl_release <= #{release_sql})
        ORDER BY a.latest_ensembl_release DESC, a.name ASC
        LIMIT 1
      )
    SQL
  end

  def self.assembly_covers_target_release_sql(release_sql)
    <<~SQL.squish
      EXISTS (
        SELECT 1
        FROM assemblies a
        WHERE a.organism_id = organisms.id
          AND #{release_sql} > 0
          AND (a.first_ensembl_release IS NULL OR a.first_ensembl_release <= #{release_sql})
          AND (a.latest_ensembl_release IS NULL OR a.latest_ensembl_release >= #{release_sql})
      )
    SQL
  end
  private_class_method :assembly_name_for_target_release_sql,
                       :assembly_release_for_target_release_sql,
                       :assembly_name_covering_target_release_sql,
                       :assembly_name_fallback_for_target_release_sql,
                       :assembly_release_covering_target_release_sql,
                       :assembly_release_fallback_for_target_release_sql,
                       :assembly_covers_target_release_sql

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

