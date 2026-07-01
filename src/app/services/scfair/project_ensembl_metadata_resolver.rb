# frozen_string_literal: true

module Scfair
  # Resolves Ensembl release, database, and assembly for a project from its
  # Version (env_json tool_versions + asap_data_db_name) and Organism.
  class ProjectEnsemblMetadataResolver
    COVID_TAX_ID = 2697049
    VERTEBRATES_SUBDOMAIN = 'vertebrates'

    def self.call(project, lookup: nil)
      new(project, lookup: lookup).call
    end

    def initialize(project, lookup: nil)
      @project = project
      @lookup_override = lookup
    end

    def call
      organism = @project.organism
      version = @project.version_for_catalog
      return nil unless organism&.tax_id.present? && version

      env = version.env_data
      tool_versions = env['tool_versions'] || {}
      remote_db = asap_data_db_name(env)
      release = resolve_release(organism, tool_versions)
      database = resolve_database(organism)
      assembly = resolve_assembly(organism, release, remote_db)

      result = {}
      result[:ensembl_release] = release.to_s if release.present?
      result[:ensembl_database] = database if database.present?
      result[:ensembl_assembly] = assembly if assembly.present?
      result.presence
    end

    private

    def asap_data_db_name(env)
      env['asap_data_db_name'].presence ||
        (env['asap_data_db_version'].present? && "asap_data_v#{env['asap_data_db_version']}")
    end

    def resolve_release(organism, tool_versions)
      return nil if tool_versions.blank?

      if organism.tax_id.to_i == COVID_TAX_ID
        tool_versions['ensembl_genomes'] || tool_versions['ensembl_vertebrate']
      elsif organism.ensembl_subdomain&.name == VERTEBRATES_SUBDOMAIN
        tool_versions['ensembl_vertebrate']
      else
        tool_versions['ensembl_genomes']
      end
    end

    def resolve_database(organism)
      return 'EnsemblCOVID-19' if organism.tax_id.to_i == COVID_TAX_ID
      return 'Ensembl' if organism.ensembl_subdomain&.name == VERTEBRATES_SUBDOMAIN
      return 'EnsemblMetazoa' if organism.ensembl_subdomain_id.present?

      nil
    end

    def resolve_assembly(organism, release, remote_db)
      return nil if release.blank? || remote_db.blank?

      lookup = @lookup_override || EnsemblReferenceLookup.new(remote_db: remote_db)
      return nil unless lookup.remote_available?

      lookup.assembly_name_at_release_for_organism(organism.tax_id, release)
    end
  end
end
