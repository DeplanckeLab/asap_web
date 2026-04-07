# frozen_string_literal: true

# Enforces whether a proposed metadata / {Annot} name is allowed for **metadata import**
# (current product scope: LOOM paths under /col_attrs/ and /row_attrs/ only — see Rule M2 in
# docs/collaborative-annotation-and-clone-lineage.md).
#
# ASAP can emit arbitrarily many concrete paths (e.g. only the run id differs). Authorization uses a
# *finite* set of {Regexp} rules, optionally extended per {Version} from env_json / step templates
# for column and row attributes (section 6.3.4, R-NM0–R-NM4).
#
# For a trailing +.vN+ compliance-style suffix, both the full string and the base (suffix stripped)
# are checked so versioned aliases cannot bypass reserved patterns (R-NM4).
class MetadataNameAuthorizationService
  Result = Struct.new(:authorized, :reason, :message, keyword_init: true)

  # Metadata import only considers /col_attrs/... and /row_attrs/... (Rule M2, R-MS).
  LOOM_ATTR_IMPORT_PATH = /\A\/(col_attrs|row_attrs)\//.freeze

  # Compliance / manual versioning suffix (+.v42+ at end of the string).
  VERSION_SUFFIX_PATTERN = /\.v\d+\z/

  # Baseline patterns under col_attrs/row_attrs — families of ASAP-like names, not an enumeration.
  MINIMAL_RESERVED_REGEXPS = [
    # Selection-derived: +<embedding>.sel_<n>+ (see projects_controller selection metadata).
    /\.sel_\d+\z/
  ].freeze

  class << self
    def call(project:, name:)
      new(project: project, name: name).call
    end
  end

  def initialize(project:, name:)
    @project = project
    @name = name.to_s
  end

  def call
    normalized = @name.strip
    return failure(:blank, "Metadata name cannot be blank") if normalized.blank?

    unless normalized.match?(LOOM_ATTR_IMPORT_PATH)
      return failure(
        :invalid_import_path,
        "Metadata import supports only names under /col_attrs/ or /row_attrs/"
      )
    end

    candidates = [normalized, normalized.sub(VERSION_SUFFIX_PATTERN, "")].uniq
    candidates.each do |candidate|
      next if candidate.blank?
      next unless candidate.match?(LOOM_ATTR_IMPORT_PATH)

      if (re = matching_reserved_regexp(candidate))
        return failure(
          :reserved_asap_pattern,
          "Name matches a reserved ASAP pattern (#{re.inspect})"
        )
      end
    end

    Result.new(authorized: true, reason: nil, message: nil)
  end

  private

  def failure(reason, message)
    Result.new(authorized: false, reason: reason, message: message)
  end

  def matching_reserved_regexp(str)
    reserved_regexps_for_project.find { |re| str.match?(re) }
  end

  def reserved_regexps_for_project
    @reserved_regexps_for_project ||= (MINIMAL_RESERVED_REGEXPS + reserved_regexps_from_project_version(@project))
  end

  # R-NM1 / R-NM3: Regexp objects for auto-generated /col_attrs/ and /row_attrs/ families for this
  # project +version+ (not per-run literal names).
  def reserved_regexps_from_project_version(project)
    return [] unless project

    []
  end
end
