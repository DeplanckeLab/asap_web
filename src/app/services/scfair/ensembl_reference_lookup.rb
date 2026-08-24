# frozen_string_literal: true

module Scfair
  # Resolves organism, assembly, and gene annotation data from the ASAP reference DB.
  class EnsemblReferenceLookup
    SPIKE_IN_TAXON = 'NCBITaxon:32630'

    def initialize(remote_db: nil, release_gene_names: nil)
      @remote_db = remote_db.presence || default_remote_db
      @release_gene_names = release_gene_names || EnsemblReleaseGeneNameResolver.new
    end

    def remote_available?
      return @remote_available unless @remote_available.nil?

      @remote_available = begin
        db = @remote_db.to_s
        db.present? && RemoteOrganism.remote_versions.include?(db)
      rescue StandardError
        false
      end
    end

    def remote_organism_for_tax_id(tax_id)
      return nil unless remote_available?

      RemoteOrganism.with_remote(@remote_db) do
        prefer_reference_organism(RemoteOrganism.where(tax_id: tax_id.to_i).to_a)
      end
    rescue StandardError
      nil
    end

    def assemblies_for_tax_id(tax_id)
      db = assemblies_remote_db
      return [] unless assemblies_remote_available?

      RemoteAssembly.with_remote(db) do
        organism = prefer_reference_organism(RemoteOrganism.where(tax_id: tax_id.to_i).to_a)
        return [] unless organism

        RemoteAssembly.where(organism_id: organism.id).order(:name).to_a
      end
    rescue StandardError
      []
    end

    def assembly_matches_name?(assemblies, reported_name)
      normalized = normalize_assembly_name(reported_name)
      return false if normalized.blank?

      assemblies.any? do |assembly|
        candidate = normalize_assembly_name(assembly.name)
        candidate == normalized ||
          candidate.start_with?(normalized) ||
          normalized.start_with?(candidate)
      end
    end

    def assembly_supports_release?(assembly, release)
      release = release.to_i
      return false unless release.positive?

      first = assembly.first_ensembl_release.to_i
      latest = assembly.latest_ensembl_release.to_i
      return false if first.positive? && release < first
      return false if latest.positive? && release > latest

      true
    end

    def release_supported_by_organism?(tax_id, release)
      assemblies_for_tax_id(tax_id).any? { |assembly| assembly_supports_release?(assembly, release) }
    end

    def matching_assemblies(assemblies, reported_name, release: nil)
      normalized = normalize_assembly_name(reported_name)
      assemblies.select do |assembly|
        candidate = normalize_assembly_name(assembly.name)
        name_match = candidate == normalized ||
                     candidate.start_with?(normalized) ||
                     normalized.start_with?(candidate)
        next false unless name_match
        next true if release.blank?

        assembly_supports_release?(assembly, release)
      end
    end

    def gene_status_at_release(organism_id:, release:, symbol: nil, ensembl_id: nil)
      return :unavailable unless remote_available?

      gene = lookup_gene(organism_id:, symbol:, ensembl_id:)
      return :not_found if gene.nil?

      status_for_release_window(
        first_ensembl_release: gene.first_ensembl_release,
        latest_ensembl_release: gene.latest_ensembl_release,
        release: release
      )
    rescue StandardError
      :unavailable
    end

    # Batch variant of gene_status_at_release for var-index checks.
    # Returns { normalized_ensembl_id => :ok|:not_found|:too_new|:deprecated|:unavailable }
    def gene_statuses_at_release(organism_id:, release:, ensembl_ids:)
      normalized_ids = Array(ensembl_ids).map { |value| normalize_ensembl_id(value) }.compact
      return {} if normalized_ids.empty?
      return normalized_ids.index_with { :unavailable } unless remote_available?

      windows = RemoteGene.find_release_windows_by_organism_and_ensembls(
        organism_id,
        normalized_ids,
        version: @remote_db
      )

      normalized_ids.index_with do |ensembl_id|
        window = windows[ensembl_id.downcase]
        next :not_found unless window

        status_for_release_window(
          first_ensembl_release: window[:first_ensembl_release],
          latest_ensembl_release: window[:latest_ensembl_release],
          release: release
        )
      end
    rescue StandardError
      normalized_ids.index_with { :unavailable }
    end

    def normalize_ensembl_id(value)
      id = value.to_s.strip
      return nil if id.blank?

      id.sub(/\.\d+\z/, '')
    end

    def spike_in_feature_name?(value)
      value.to_s.match?(/ERCC|spike-in control/i)
    end

    def spike_in_feature_name_format_valid?(value)
      value.to_s.match?(/\AERCC-\d+ \(spike-in control\)\z/i)
    end

    def known_gene_reference_taxon?(reference)
      FeatureReferenceTaxonPolicy.allowed_gene_reference?(reference)
    end

    def gene_for_reference_and_index(feature_reference, index_id)
      return nil unless remote_available?

      tax_id = extract_tax_id(feature_reference)
      return nil unless tax_id

      organism = remote_organism_for_tax_id(tax_id)
      return nil unless organism

      lookup_gene(organism_id: organism.id, symbol: nil, ensembl_id: normalize_ensembl_id(index_id))
    rescue StandardError
      nil
    end

    def preload_release_gene_names(feature_reference:, release:, ensembl_ids:)
      return unless remote_available?
      return unless @release_gene_names.available?

      tax_id = extract_tax_id(feature_reference)
      return unless tax_id

      organism = remote_organism_for_tax_id(tax_id)
      return unless organism

      db_type = ensembl_subdomain_for_organism(organism)
      return unless db_type

      @release_gene_names.preload!(
        db_type: db_type,
        ensembl_db_name: organism.ensembl_db_name,
        release: release,
        ensembl_ids: ensembl_ids
      )
    rescue StandardError
      nil
    end

    def expected_feature_name(feature_reference:, index_id:, biotype:, release: nil)
      index = index_id.to_s.strip
      return nil if index.blank?

      case biotype.to_s
      when 'spike-in'
        spike_in_feature_name_for_index(index)
      when 'gene'
        normalized_index = normalize_ensembl_id(index)
        release_name = release_gene_name(
          feature_reference: feature_reference,
          ensembl_id: normalized_index,
          release: release
        )
        return release_name if release_name.present?

        return normalized_index unless remote_available?

        gene = gene_for_reference_and_index(feature_reference, index)
        gene&.name.presence || normalized_index
      end
    end

    def spike_in_feature_name_for_index(index_id)
      "#{index_id} (spike-in control)"
    end

    def allowed_feature_reference?(reference, biotype:)
      FeatureReferenceTaxonPolicy.allowed?(reference, biotype:)
    end

    def feature_reference_policy
      Rules.feature_reference_policy
    end

    def extract_tax_id(term_id)
      match = term_id.to_s.match(/\ANCBITaxon:(\d+)\z/)
      return nil unless match

      match[1].to_i
    end

    def latest_release_for_assembly(feature_reference:, assembly_name: nil)
      resolve_release_for_gene_reference(
        feature_reference: feature_reference,
        ensembl_assembly: assembly_name
      )
    end

    def resolve_release_for_gene_reference(feature_reference:, ensembl_release: nil, ensembl_assembly: nil)
      release = parse_release_value(ensembl_release)
      return release if release

      tax_id = extract_tax_id(feature_reference)
      return nil unless tax_id

      if ensembl_assembly.present?
        return latest_release_for_assembly_name(tax_id, ensembl_assembly)
      end

      latest_local_release_for_organism(tax_id) || latest_release_from_assemblies(tax_id)
    rescue StandardError
      nil
    end

    def assembly_for_gene_reference(feature_reference:, ensembl_release: nil, ensembl_assembly: nil)
      return ensembl_assembly.to_s.strip.presence if ensembl_assembly.present?

      release = resolve_release_for_gene_reference(
        feature_reference: feature_reference,
        ensembl_release: ensembl_release,
        ensembl_assembly: ensembl_assembly
      )
      return nil unless release

      tax_id = extract_tax_id(feature_reference)
      return nil unless tax_id

      assembly_name_at_release(tax_id, release)
    rescue StandardError
      nil
    end

    # Assembly name for an organism at a given Ensembl release (latest assemblies DB).
    def assembly_name_at_release_for_organism(tax_id, release)
      release = parse_release_value(release)
      return nil unless release

      assemblies = assemblies_for_tax_id(tax_id)
      matched = assemblies.select { |assembly| assembly_supports_release?(assembly, release) }
      return nil if matched.empty?

      matched.max_by { |assembly| assembly.latest_ensembl_release.to_i }&.name
    rescue StandardError
      nil
    end

    # INSDC accession for Ensembl genome-browser URLs (e.g. GCA_002204515.1 for AaegL5).
    def insdc_accession_for_assembly(tax_id, assembly_name, release: nil)
      assemblies = assemblies_for_tax_id(tax_id)
      matched = matching_assemblies(assemblies, assembly_name, release: release)
      return nil if matched.empty?

      record = matched.find { |assembly| assembly.insdc_accession.to_s.strip.present? } || matched.first
      accession = record.insdc_accession.to_s.strip.presence
      return accession if accession.present?

      name = record.name.to_s.strip
      return name if name.match?(/\AGCA[_\d]/i)

      nil
    rescue StandardError
      nil
    end

    def genome_browser_assembly(tax_id:, assembly_name:, release: nil)
      insdc_accession_for_assembly(tax_id, assembly_name, release: release)
    rescue StandardError
      nil
    end

    def release_gene_name(feature_reference:, ensembl_id:, release:)
      return nil if release.blank?
      return nil unless remote_available?
      return nil unless @release_gene_names.available?

      tax_id = extract_tax_id(feature_reference)
      return nil unless tax_id

      organism = remote_organism_for_tax_id(tax_id)
      return nil unless organism

      db_type = ensembl_subdomain_for_organism(organism)
      return nil unless db_type

      @release_gene_names.gene_name_for(
        ensembl_id,
        db_type: db_type,
        ensembl_db_name: organism.ensembl_db_name,
        release: release
      )
    rescue StandardError
      nil
    end

    def ensembl_subdomain_for_organism(organism)
      subdomain_id = organism.ensembl_subdomain_id.to_i
      return nil unless subdomain_id.positive?

      RemoteOrganism.with_remote(@remote_db) do
        row = RemoteOrganism.connection.select_one(<<~SQL.squish)
          SELECT name FROM ensembl_subdomains WHERE id = #{subdomain_id} LIMIT 1
        SQL
        row&.[]('name')&.to_sym
      end
    rescue StandardError
      nil
    end

    def assemblies_for_tax_id_any_version(tax_id)
      assemblies_for_tax_id(tax_id)
    end

    def assemblies_remote_db
      Asap2RemoteRecord.latest_remote_db
    end

    def assemblies_remote_available?
      db = assemblies_remote_db
      db.present? && RemoteOrganism.remote_versions.include?(db)
    end

    private

    def default_remote_db
      RemoteOrganism.send(:default_remote_db)
    rescue StandardError
      nil
    end

    # Prefer the reference Ensembl species DB (e.g. mus_musculus) over strain DBs
    # that share the same NCBI tax_id (e.g. mus_musculus_balbcj).
    def prefer_reference_organism(organisms)
      return nil if organisms.blank?
      return organisms.first if organisms.size == 1

      reference = organisms.select { |organism| organism.ensembl_db_name.to_s.split('_').size == 2 }
      (reference.presence || organisms).min_by(&:id)
    end

    def status_for_release_window(first_ensembl_release:, latest_ensembl_release:, release:)
      release_i = release.to_i
      first = first_ensembl_release.to_i
      return :too_new if first.positive? && release_i < first

      latest = latest_ensembl_release.to_i
      return :deprecated if latest.positive? && release_i > latest

      :ok
    end

    def lookup_gene(organism_id:, symbol: nil, ensembl_id: nil)
      if ensembl_id.present?
        return RemoteGene.find_by_organism_and_ensembl(organism_id, ensembl_id, version: @remote_db)
      end

      return nil if symbol.blank?

      RemoteGene.find_by_organism_and_symbol(organism_id, symbol, version: @remote_db)
    end

    def normalize_assembly_name(value)
      value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '')
    end

    def parse_release_value(value)
      raw = value.to_s.strip
      return nil if raw.blank? || !raw.match?(/\A\d+\z/)

      release = raw.to_i
      release.positive? ? release : nil
    end

    def latest_release_for_assembly_name(tax_id, assembly_name)
      assemblies = assemblies_for_tax_id_any_version(tax_id)
      matched = matching_assemblies(assemblies, assembly_name)
      return nil if matched.empty?

      matched.map { |a| a.latest_ensembl_release.to_i }.select(&:positive?).max
    end

    def latest_release_from_assemblies(tax_id)
      assemblies = assemblies_for_tax_id_any_version(tax_id)
      return nil if assemblies.empty?

      assemblies.map { |a| a.latest_ensembl_release.to_i }.select(&:positive?).max
    end

    def assembly_name_at_release(tax_id, release)
      assemblies = assemblies_for_tax_id_any_version(tax_id)
      matched = assemblies.select { |assembly| assembly_supports_release?(assembly, release) }
      return nil if matched.empty?

      matched.max_by { |assembly| assembly.latest_ensembl_release.to_i }&.name
    end

    def latest_local_release_for_organism(tax_id)
      return nil unless @release_gene_names.available?

      organism = remote_organism_for_tax_id(tax_id)
      return nil unless organism

      db_type = ensembl_subdomain_for_organism(organism)
      return nil unless db_type

      base_dirs = AsapData::EnsemblAssembliesLoader.all_ensembl_base_dirs
      releases = AsapData::EnsemblAssembliesLoader.available_release_numbers(base_dirs, db_type)
      organism_releases = releases.select do |rel|
        release_dir = AsapData::EnsemblAssembliesLoader.resolve_release_dir(base_dirs, db_type, rel)
        release_dir &&
          AsapData::EnsemblAssembliesLoader.organism_present_in_release?(release_dir, organism.ensembl_db_name)
      end
      organism_releases.last
    end
  end
end
