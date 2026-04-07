# frozen_string_literal: true

# Creates a {Fu}, normalizes clipboard import content, writes staged `clipboard.txt`, and returns
# preview metadata. Used by {ProjectsController#prepare_metadata} and cross-project annot prepare.
class MetadataImportPrepareStaging
  DELIMITERS = ["\n", "\t", " ", ";", ","].freeze

  class << self
    def call(project:, user_id:, raw_content:, metadata_type_id:, input_type_id:, delimiter_idx:, name:, has_header:)
      new(
        project: project,
        user_id: user_id,
        raw_content: raw_content,
        metadata_type_id: metadata_type_id.to_s,
        input_type_id: input_type_id.to_s,
        delimiter_idx: delimiter_idx.to_i,
        name: name.to_s,
        has_header: has_header
      ).call
    end
  end

  def initialize(project:, user_id:, raw_content:, metadata_type_id:, input_type_id:, delimiter_idx:, name:, has_header:)
    @project = project
    @user_id = user_id
    @raw_content = raw_content.to_s
    @metadata_type_id = metadata_type_id
    @input_type_id = input_type_id
    @delimiter_idx = delimiter_idx
    @name = name
    @has_header = has_header
  end

  def call
    fu = create_fu
    fu_dir = fu.upload_dir
    FileUtils.mkdir_p(fu_dir)
    filepath = fu_dir + "clipboard.txt"

    duplicates = []
    h_identifiers = {}
    final_content = []
    header_name = nil

    if @metadata_type_id == "4"
      @raw_content.split(/\n/).each do |line|
        line = line.strip
        next if line.empty?

        final_content.push(line)
      end
    elsif @input_type_id == "2"
      lines = @raw_content.split(/\n/)
      lines.each_with_index do |line, idx|
        if idx == 0 && @has_header
          final_content.push(line)
          next
        end
        parts = line.split(/\t/)
        identifier = parts[0]
        if identifier && !h_identifiers[identifier]
          h_identifiers[identifier] = 1
          final_content.push(line)
        elsif identifier
          duplicates.push(identifier)
        end
      end
    elsif @input_type_id == "1"
      delimiter = DELIMITERS[@delimiter_idx] || "\n"
      entries = @raw_content.split(/#{Regexp.escape(delimiter)}+/).map(&:strip).reject(&:empty?)

      if @has_header && entries.any?
        header_name = entries.shift
        header_prefix = @metadata_type_id == "2" ? "genes" : "cells"
        final_content.push("#{header_prefix}\t#{header_name}")
      end

      entries.each do |e|
        if !h_identifiers[e]
          h_identifiers[e] = 1
          final_content.push("#{e}\t1")
        else
          duplicates.push(e)
        end
      end
    end

    File.open(filepath, "w") { |f| f.write(final_content.join("\n")) }

    if File.exist?(filepath) && File.size(filepath) > 0
      fu.update(
        status: "written",
        upload_file_size: File.size(filepath),
        upload_updated_at: Time.now
      )
    end

    {
      fu: fu,
      filepath: filepath,
      duplicates: duplicates,
      final_content: final_content,
      header_name: header_name
    }
  end

  private

  def create_fu
    h_fu = {
      project_id: @project.id,
      project_key: @project.key,
      status: "new",
      upload_type: 2,
      upload_file_name: "clipboard.txt",
      upload_content_type: "text/plain",
      user_id: @user_id
    }
    fu = Fu.new(h_fu)
    fu.save!
    fu
  end
end
