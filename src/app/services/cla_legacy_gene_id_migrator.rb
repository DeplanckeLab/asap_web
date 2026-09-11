# frozen_string_literal: true

require "fileutils"

# Migrates Cla up/down gene fields from legacy asap_data genes.id values to loom
# /row_attrs/_StableID values used by the modern annotation UI.
#
# Mapping path:
#   1. genes.id -> genes.ensembl_id -> autocomplete stable id
#   2. if ensembl miss: genes.name -> autocomplete symbol (exact, case-insensitive)
#      only when that symbol maps to exactly one stable id
#
# Ambiguous or missing symbol matches are reported and left unchanged.
class ClaLegacyGeneIdMigrator
  FIELD_NAMES = %i[up_gene_ids sorted_up_gene_ids down_gene_ids sorted_down_gene_ids].freeze
  # Loom _StableID values are row indexes; asap_data genes.id values for imported
  # SCope/manual clas are much larger. Only candidates above this threshold are
  # considered for migration (then verified against genes).
  LEGACY_GENE_ID_MIN = 100_000

  Result = Struct.new(
    :cla_id,
    :project_id,
    :project_key,
    :action,
    :reason,
    :field_changes,
    :unresolved,
    :resolved_via,
    keyword_init: true
  )

  def self.call(cla, dry_run: true, caches: nil)
    new(caches: caches).call(cla, dry_run: dry_run)
  end

  def initialize(caches: nil)
    @caches = caches || {
      project: {},
      db_name: {},
      gene_by_id: {},
      autocomplete_by_project_annot: {}
    }
  end

  def call(cla, dry_run: true)
    project = project_for(cla)
    unless project
      return Result.new(
        cla_id: cla.id,
        project_id: cla.project_id,
        project_key: nil,
        action: :skip,
        reason: :missing_project,
        field_changes: {},
        unresolved: [],
        resolved_via: {}
      )
    end

    db_name = db_name_for(project)
    unless db_name
      return Result.new(
        cla_id: cla.id,
        project_id: project.id,
        project_key: project.key,
        action: :skip,
        reason: :missing_asap_data_db_name,
        field_changes: {},
        unresolved: [],
        resolved_via: {}
      )
    end

    autocomplete = autocomplete_for(project, cla.annot)
    unless autocomplete
      return Result.new(
        cla_id: cla.id,
        project_id: project.id,
        project_key: project.key,
        action: :skip,
        reason: :missing_autocomplete,
        field_changes: {},
        unresolved: [],
        resolved_via: {}
      )
    end

    field_changes = {}
    unresolved = []
    resolved_via = Hash.new(0)
    any_legacy = false

    FIELD_NAMES.each do |field|
      raw = cla.public_send(field).to_s.strip
      next if raw.blank?

      ids = parse_ids(raw)
      next if ids.empty?

      mapped = []
      field_unresolved = []
      ids.each do |gid|
        if legacy_gene_id_candidate?(gid)
          any_legacy = true
          resolution = resolve_legacy_gene_id(gid, db_name, autocomplete)
          if resolution[:stable_id]
            mapped << resolution[:stable_id]
            resolved_via[resolution[:via]] += 1
          else
            field_unresolved << resolution.merge(field: field, gene_id: gid)
            mapped << gid
          end
        else
          mapped << gid
        end
      end

      unresolved.concat(field_unresolved)

      new_raw =
        if field.to_s.start_with?("sorted_")
          mapped.map { |v| v.to_s }.sort_by { |v| v.to_i }.join(",")
        else
          mapped.join(",")
        end

      field_changes[field] = { from: raw, to: new_raw } if new_raw != raw
    end

    unless any_legacy
      return Result.new(
        cla_id: cla.id,
        project_id: project.id,
        project_key: project.key,
        action: :skip,
        reason: :no_legacy_gene_ids,
        field_changes: {},
        unresolved: [],
        resolved_via: {}
      )
    end

    if unresolved.any?
      return Result.new(
        cla_id: cla.id,
        project_id: project.id,
        project_key: project.key,
        action: :unresolved,
        reason: :stable_id_not_found,
        field_changes: field_changes,
        unresolved: unresolved,
        resolved_via: resolved_via
      )
    end

    if field_changes.empty?
      return Result.new(
        cla_id: cla.id,
        project_id: project.id,
        project_key: project.key,
        action: :skip,
        reason: :already_migrated,
        field_changes: {},
        unresolved: [],
        resolved_via: resolved_via
      )
    end

    unless dry_run
      attrs = field_changes.transform_values { |change| change[:to] }
      cla.update!(attrs)
    end

    Result.new(
      cla_id: cla.id,
      project_id: project.id,
      project_key: project.key,
      action: dry_run ? :would_update : :updated,
      reason: nil,
      field_changes: field_changes,
      unresolved: [],
      resolved_via: resolved_via
    )
  end

  def clear_autocomplete_cache_for_project!(project_id)
    @caches[:autocomplete_by_project_annot].delete_if { |(pid, _), _| pid == project_id }
  end

  def autocomplete_available?(project, annot = nil)
    !autocomplete_for(project, annot).nil?
  end

  def user_data_project_dir(project)
    Pathname.new(ENV.fetch("USER_DATA_DIR")) + project.user_id.to_s + project.key
  end

  # Ensure loom autocomplete is readable. If the project is archived on S3 and local
  # data is missing, temporarily unarchive into USER_DATA_DIR.
  # Returns:
  #   { status: :present }
  #   { status: :unarchived, disk_size_archived: Integer/nil }
  #   { status: :unarchive_failed|:busy|:not_restorable, detail: ... }
  def ensure_local_data!(project)
    if autocomplete_available?(project)
      return { status: :present }
    end

    if project.being_unarchived? || project.being_archived?
      return { status: :busy, detail: "archive_status_id=#{project.archive_status_id}" }
    end

    unless project.archived_on_s3? || project.archive_restore_expected?
      return { status: :not_restorable, detail: "archive_status_id=#{project.archive_status_id}" }
    end

    saved_size = project.disk_size_archived
    ok = Basic.unarchive(project.key)
    project.reload
    clear_autocomplete_cache_for_project!(project.id)

    unless ok && autocomplete_available?(project)
      return {
        status: :unarchive_failed,
        detail: "Basic.unarchive=#{ok} autocomplete_available=#{autocomplete_available?(project)}"
      }
    end

    { status: :unarchived, disk_size_archived: saved_size }
  end

  # Delete local USER_DATA_DIR files and mark the project archived again.
  # Does not re-upload to S3 (archive already exists there).
  def restore_archived!(project, disk_size_archived:)
    dir = user_data_project_dir(project)
    tgz = Pathname.new("#{dir}.tgz")
    FileUtils.rm_r(dir.to_s) if File.exist?(dir.to_s)
    File.delete(tgz.to_s) if File.exist?(tgz.to_s)
    project.update_archive_metadata!(
      archive_status_id: 3,
      disk_size_archived: disk_size_archived
    )
    clear_autocomplete_cache_for_project!(project.id)
    true
  end

  private

  def resolve_legacy_gene_id(gid, db_name, autocomplete)
    gene = gene_row(db_name, gid)
    unless gene
      return { reason: :unknown_gene_id }
    end

    ensembl = gene[:ensembl_id].to_s.strip
    gene_name = gene[:name].to_s.strip
    symbol_hits = gene_name.present? ? (autocomplete[:by_symbol][gene_name.downcase] || []) : []

    if ensembl.present?
      stable = autocomplete[:by_ensembl][ensembl.downcase]
      if stable
        return {
          stable_id: stable,
          via: :ensembl_id,
          ensembl_id: ensembl,
          gene_name: gene_name
        }
      end
    end

    stable_ids = symbol_hits.map { |hit| hit[:stable_id] }.uniq
    if stable_ids.size == 1
      return {
        stable_id: stable_ids.first,
        via: :gene_name,
        ensembl_id: ensembl.presence,
        gene_name: gene_name,
        autocomplete_symbol_hits: symbol_hits.map { |hit| hit[:label] },
        matched_ensembl_id: symbol_hits.first[:ensembl_id]
      }
    end

    if stable_ids.size > 1
      return {
        reason: :ambiguous_gene_name,
        ensembl_id: ensembl.presence,
        gene_name: gene_name,
        autocomplete_symbol_hits: symbol_hits.map { |hit| hit[:label] }
      }
    end

    {
      reason: ensembl.blank? ? :blank_ensembl_id : :stable_id_not_found,
      ensembl_id: ensembl.presence,
      gene_name: gene_name,
      autocomplete_symbol_hits: []
    }
  end

  def project_for(cla)
    pid = cla.project_id
    return @caches[:project][pid] if @caches[:project].key?(pid)

    @caches[:project][pid] = Project.find_by(id: pid)
  end

  def db_name_for(project)
    return @caches[:db_name][project.id] if @caches[:db_name].key?(project.id)

    h_env = Basic.safe_parse_json(project.version&.env_json, {})
    name = h_env["asap_data_db_name"].to_s.strip
    name = "asap_data_v#{h_env['asap_data_db_version']}" if name.blank? && h_env["asap_data_db_version"].present?
    @caches[:db_name][project.id] = name.presence
  end

  def gene_row(db_name, gene_id)
    key = [db_name, gene_id.to_s]
    return @caches[:gene_by_id][key] if @caches[:gene_by_id].key?(key)

    row = RemoteGene.find_by_remote_id(gene_id.to_i, version: db_name)
    @caches[:gene_by_id][key] =
      if row
        { id: row.id, ensembl_id: row.ensembl_id.to_s, name: row.name.to_s }
      end
  end

  def autocomplete_for(project, annot)
    cache_key = [project.id, annot&.id, annot&.filepath.to_s]
    return @caches[:autocomplete_by_project_annot][cache_key] if @caches[:autocomplete_by_project_annot].key?(cache_key)

    paths = autocomplete_paths_for(project, annot)
    by_ensembl = {}
    by_symbol = Hash.new { |h, k| h[k] = [] }
    paths.each do |path|
      merge_autocomplete_file!(by_ensembl, by_symbol, path)
    end

    @caches[:autocomplete_by_project_annot][cache_key] =
      if by_ensembl.empty?
        nil
      else
        { by_ensembl: by_ensembl, by_symbol: by_symbol, paths: paths }
      end
  end

  def autocomplete_paths_for(project, annot)
    roots = project_data_roots(project)
    preferred = []
    others = []

    roots.each do |root|
      if annot&.filepath.present?
        preferred_path = root + File.dirname(annot.filepath.to_s) + "autocomplete_genes.json"
        preferred << preferred_path if preferred_path.exist?
      end
      Dir.glob(root.join("**/autocomplete_genes.json").to_s).each do |path|
        pathname = Pathname.new(path)
        others << pathname unless preferred.include?(pathname)
      end
    end

    (preferred + others).uniq
  end

  def project_data_roots(project)
    return [] unless project&.user_id.present?

    roots = []
    [ENV["USER_DATA_DIR"], ENV["PROD_DATA_DIR"], ENV["DATA_DIR"]].each do |base|
      next if base.to_s.strip.empty?

      root = Pathname.new(base.to_s.chomp("/"))
      # USER_DATA_DIR already ends with /users; PROD/DATA may be the instance root.
      candidates = []
      if root.basename.to_s == "users"
        candidates << (root + project.user_id.to_s + project.key)
      else
        candidates << (root + "users" + project.user_id.to_s + project.key)
        candidates << (root + project.user_id.to_s + project.key)
      end
      candidates.each { |path| roots << path if path.exist? }
    end
    roots.uniq
  end

  def merge_autocomplete_file!(by_ensembl, by_symbol, path)
    data = JSON.parse(File.read(path.to_s))
    Array(data["search"] || data[:search]).each do |entry|
      parsed = parse_autocomplete_entry(entry)
      next unless parsed
      next if parsed[:ensembl_id].blank?

      key = parsed[:ensembl_id].downcase
      existing = by_ensembl[key]
      if existing && existing != parsed[:stable_id]
        # Prefer the first (preferred loom) mapping; do not overwrite with conflicts.
      else
        by_ensembl[key] = parsed[:stable_id]
      end

      symbol_key = parsed[:symbol].to_s.downcase
      next if symbol_key.blank?

      hit = {
        symbol: parsed[:symbol],
        ensembl_id: parsed[:ensembl_id],
        stable_id: parsed[:stable_id],
        label: "#{parsed[:symbol]} #{parsed[:ensembl_id]} {#{parsed[:stable_id]}}"
      }
      unless by_symbol[symbol_key].any? { |existing_hit| existing_hit[:label] == hit[:label] }
        by_symbol[symbol_key] << hit
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[ClaLegacyGeneIdMigrator] Failed reading #{path}: #{e.class} - #{e.message}")
  end

  def parse_autocomplete_entry(entry)
    match = entry.to_s.strip.match(/\A(.+?)\s+(\S+)\s+\{([^}]+)\}\z/)
    return nil unless match

    symbol = match[1].to_s.strip
    ensembl_id = match[2].to_s.strip
    stable_id = match[3].to_s.strip
    return nil if symbol.blank? || stable_id.blank?

    { symbol: symbol, ensembl_id: ensembl_id, stable_id: stable_id }
  end

  def parse_ids(value)
    value.to_s.split(",").map { |item| item.to_s.strip }.reject(&:blank?)
  end

  def legacy_gene_id_candidate?(value)
    text = value.to_s.strip
    return false unless text.match?(/\A\d+\z/)

    text.to_i >= LEGACY_GENE_ID_MIN
  end
end
