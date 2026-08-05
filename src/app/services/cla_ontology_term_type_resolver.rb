# frozen_string_literal: true

# Resolves ontology_term_type_id from CellOntologyTerm ids on a Cla.
#
# Candidates are OntologyTermType rows whose cell_ontology_ids cover every COT's
# cell_ontology_id. When rules.yaml semantic_rules exist for the OTT term_path
# field, candidates are further filtered by any_roots / allowed_exact /
# forbidden_branches / forbidden_exact (via OntologyLineageResolver).
#
# Returns a single ontology_term_type_id when uniquely determined; otherwise nil.
class ClaOntologyTermTypeResolver
  Result = Struct.new(:ontology_term_type_id, :candidate_ids, :status, keyword_init: true)

  class << self
    def call(cot_ids, resolver: nil)
      new(cot_ids, resolver: resolver).call
    end

    def ontology_term_type_id_for(cot_ids, resolver: nil)
      call(cot_ids, resolver: resolver).ontology_term_type_id
    end

    # Group each COT id by the uniquely resolved OntologyTermType id.
    # Unresolved / ambiguous / missing terms are keyed under nil.
    # Returns { ontology_term_type_id_or_nil => [cot_id, ...] } preserving first-seen order.
    def group_cot_ids_by_type(cot_ids, resolver: nil)
      new(cot_ids, resolver: resolver).group_cot_ids_by_type
    end
  end

  def initialize(cot_ids, resolver: nil)
    @cot_ids = self.class.normalize_ids(cot_ids)
    @lineage_resolver = resolver || Scfair::OntologyLineageResolver.new
  end

  def call
    return Result.new(ontology_term_type_id: nil, candidate_ids: [], status: :empty) if @cot_ids.empty?

    terms = CellOntologyTerm.where(id: @cot_ids).includes(:cell_ontology).to_a
    return Result.new(ontology_term_type_id: nil, candidate_ids: [], status: :missing_terms) if terms.size != @cot_ids.size

    resolve_terms(terms)
  end

  def group_cot_ids_by_type
    groups = {}
    return groups if @cot_ids.empty?

    terms_by_id = CellOntologyTerm.where(id: @cot_ids).includes(:cell_ontology).index_by(&:id)
    @cot_ids.each do |cot_id|
      term = terms_by_id[cot_id]
      key = if term.nil?
              nil
            else
              result = resolve_terms([term])
              result.status == :unique ? result.ontology_term_type_id : nil
            end
      groups[key] ||= []
      groups[key] << cot_id
    end
    groups
  end

  def self.normalize_ids(value)
    Array(value).flat_map { |v| v.to_s.split(',') }
               .map(&:strip)
               .reject(&:blank?)
               .map(&:to_i)
               .select(&:positive?)
               .uniq
  end

  private

  def resolve_terms(terms)
    co_ids = terms.map(&:cell_ontology_id).compact.uniq
    return Result.new(ontology_term_type_id: nil, candidate_ids: [], status: :missing_ontology) if co_ids.empty?

    candidates = OntologyTermType.where.not(term_path: [nil, '']).select do |ott|
      allowed = ott.cell_ontology_ids_list
      next false if allowed.empty?

      co_ids.all? { |co_id| allowed.include?(co_id) }
    end

    candidates = candidates.select { |ott| terms_match_semantic_rules?(terms, ott) }

    ids = candidates.map(&:id).sort
    if ids.size == 1
      Result.new(ontology_term_type_id: ids.first, candidate_ids: ids, status: :unique)
    elsif ids.empty?
      Result.new(ontology_term_type_id: nil, candidate_ids: [], status: :unresolved)
    else
      Result.new(ontology_term_type_id: nil, candidate_ids: ids, status: :ambiguous)
    end
  end

  def terms_match_semantic_rules?(terms, ott)
    field_name = Scfair::Rules.obs_field_name_from_path(ott.term_path)
    rules = Scfair::OntologySemanticRules.rules_for(field_name)
    return true if rules.blank?

    allowed_exact = normalize_exact_list(rules[:allowed_exact])
    forbidden_exact = Array(rules[:forbidden_exact]).map(&:to_s)
    any_roots = Array(rules[:any_roots]).map(&:to_s)
    forbidden_branches = Array(rules[:forbidden_branches]).map(&:to_s)
    allowed_specials = Array(rules[:allowed_special_values]).map(&:to_s)

    terms.all? do |term|
      identifier = term.identifier.to_s
      next true if allowed_specials.include?(identifier)
      next true if allowed_exact.include?(identifier)
      next false if forbidden_exact.include?(identifier)

      if forbidden_branches.any? { |root| @lineage_resolver.descendant_of?(identifier, root) }
        next false
      end

      if any_roots.present?
        any_roots.any? { |root| @lineage_resolver.descendant_of?(identifier, root) }
      elsif allowed_exact.present?
        # Field only allows an exact set (e.g. sex via valid_terms); identifier not in set.
        false
      else
        true
      end
    end
  end

  def normalize_exact_list(raw)
    case raw
    when Hash
      raw.keys.map(&:to_s)
    when Array
      raw.map(&:to_s)
    else
      []
    end
  end
end
