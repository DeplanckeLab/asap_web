# frozen_string_literal: true

# Writes /attrs/anndata_mapping into a project loom file from Annots + defaults,
# and creates or updates the matching Annot row (dim=4 global attribute).
class AnndataMappingPersistService
  class << self
    def call(project:, loom_filepath:, input_group: nil, only_if_changed: false)
      new(
        project: project,
        loom_filepath: loom_filepath,
        input_group: input_group,
        only_if_changed: only_if_changed
      ).call
    end

    # True when the loom has no mapping or the rebuilt document would differ.
    def needs_update?(project:, loom_filepath:, input_group: nil)
      new(project: project, loom_filepath: loom_filepath, input_group: input_group).needs_update?
    end
  end

  def initialize(project:, loom_filepath:, input_group: nil, only_if_changed: false)
    @project = project
    @loom_filepath = loom_filepath.to_s.sub(%r{\A/+}, '').sub(/\.h5ad\z/i, '.loom')
    @input_group = input_group
    @only_if_changed = only_if_changed
  end

  def needs_update?
    raise ArgumentError, 'Project is required' if @project.nil?
    raise ArgumentError, 'Loom filepath is required' if @loom_filepath.blank?
    raise ArgumentError, 'Loom filepath must end with .loom' unless @loom_filepath.end_with?('.loom')

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    loom_path = project_dir + @loom_filepath
    raise "Loom file not found: #{@loom_filepath}" unless File.exist?(loom_path)

    existing = read_existing_mapping(loom_path.to_s)
    return true if existing.nil?

    payload = AnndataMappingBuilder.call(
      project: @project,
      loom_filepath: @loom_filepath,
      input_group: @input_group,
      existing: existing
    )
    !mapping_documents_equal?(existing, payload)
  end

  def call
    raise ArgumentError, 'Project is required' if @project.nil?
    raise ArgumentError, 'Loom filepath is required' if @loom_filepath.blank?
    raise ArgumentError, 'Loom filepath must end with .loom' unless @loom_filepath.end_with?('.loom')

    project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + @project.user_id.to_s + @project.key
    loom_path = project_dir + @loom_filepath
    raise "Loom file not found: #{@loom_filepath}" unless File.exist?(loom_path)

    existing = read_existing_mapping(loom_path.to_s)
    payload = AnndataMappingBuilder.call(
      project: @project,
      loom_filepath: @loom_filepath,
      input_group: @input_group,
      existing: existing
    )
    json_string = JSON.generate(payload)

    if @only_if_changed && existing && mapping_documents_equal?(existing, payload)
      annot = @project.annots
                      .where(name: AnndataMappingBuilder::LOOM_ATTR_PATH, filepath: @loom_filepath)
                      .order(latest_version: :desc, id: :desc)
                      .first
      return {
        ok: true,
        changed: false,
        loom_filepath: @loom_filepath,
        attr_path: AnndataMappingBuilder::LOOM_ATTR_PATH,
        annot_id: annot&.id,
        x_path: payload['x_path'],
        raw_x_path: payload['raw_x_path'],
        nber_obsm: payload['obsm'].is_a?(Hash) ? payload['obsm'].size : 0,
        bytes: json_string.bytesize
      }
    end

    H5DataService.with_loom_write_lock(loom_path) do
      H5DataService.write_global_attr_string!(
        loom_path.to_s,
        AnndataMappingBuilder::LOOM_ATTR_PATH,
        json_string,
        already_locked: true
      )
    end

    annot = upsert_annot!(json_string)

    {
      ok: true,
      changed: true,
      loom_filepath: @loom_filepath,
      attr_path: AnndataMappingBuilder::LOOM_ATTR_PATH,
      annot_id: annot.id,
      x_path: payload['x_path'],
      raw_x_path: payload['raw_x_path'],
      nber_obsm: payload['obsm'].is_a?(Hash) ? payload['obsm'].size : 0,
      bytes: json_string.bytesize
    }
  end

  private

  def mapping_documents_equal?(existing, payload)
    JSON.parse(JSON.generate(existing)) == JSON.parse(JSON.generate(payload))
  end

  def read_existing_mapping(loom_path)
    raw = H5DataService.read_global_attr_string(loom_path, AnndataMappingBuilder::LOOM_ATTR_PATH)
    return nil if raw.blank?

    parsed = Basic.safe_parse_json(raw, nil)
    parsed.is_a?(Hash) ? parsed : nil
  rescue StandardError
    nil
  end

  def upsert_annot!(json_string)
    data_type_id = DataType.find_by(name: 'STRING')&.id
    raise 'STRING DataType not found' if data_type_id.nil?

    global_dc = DataClass.find_by(name: 'global_mdata')
    attrs = {
      name: AnndataMappingBuilder::LOOM_ATTR_PATH,
      label: AnndataMappingBuilder::ATTR_NAME,
      filepath: @loom_filepath,
      dim: 4,
      data_type_id: data_type_id,
      data_class_ids: global_dc ? global_dc.id.to_s : nil,
      nber_rows: 1,
      nber_cols: 1,
      mem_size: json_string.bytesize,
      imported: false,
      latest_version: true
    }

    existing = @project.annots
                       .where(name: AnndataMappingBuilder::LOOM_ATTR_PATH, filepath: @loom_filepath)
                       .order(latest_version: :desc, id: :desc)
                       .to_a
    annot = existing.first
    if annot
      existing.drop(1).each(&:destroy!)
      annot.update!(attrs)
      annot
    else
      @project.annots.create!(
        attrs.merge(
          version_nber: 1,
          user_id: @project.user_id
        )
      )
    end
  end
end
