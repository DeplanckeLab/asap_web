# frozen_string_literal: true

# Splits a Cla whose cell_ontology_term_ids resolve to more than one OntologyTermType
# into one Cla per annotation type (plus an optional untyped Cla for unresolved terms).
#
# Dry-run by default when used from the rake task (DRY_RUN!=0).
class ClaMixedOntologyTypeSplitter
  Plan = Struct.new(
    :cla_id,
    :action,
    :groups,
    :primary_ott_id,
    :primary_cot_ids,
    :creates,
    :unresolved_cot_ids,
    :message,
    keyword_init: true
  )
  CreateSpec = Struct.new(:ontology_term_type_id, :cot_ids, keyword_init: true)

  class << self
    def plan_for(cla, resolver: nil)
      new(cla, resolver: resolver).plan
    end

    def apply!(cla, dry_run: true, resolver: nil)
      new(cla, resolver: resolver).apply!(dry_run: dry_run)
    end
  end

  def initialize(cla, resolver: nil)
    @cla = cla
    @lineage_resolver = resolver
  end

  def plan
    cot_ids = ClaOntologyTermTypeResolver.normalize_ids(@cla.cell_ontology_term_ids)
    if cot_ids.size < 2
      return Plan.new(
        cla_id: @cla.id,
        action: :skip,
        groups: {},
        primary_ott_id: @cla.ontology_term_type_id,
        primary_cot_ids: cot_ids,
        creates: [],
        unresolved_cot_ids: [],
        message: 'fewer_than_two_cot_ids'
      )
    end

    groups = ClaOntologyTermTypeResolver.group_cot_ids_by_type(cot_ids, resolver: @lineage_resolver)
    typed = groups.reject { |ott_id, _| ott_id.nil? }
    unresolved = Array(groups[nil])

    if typed.size < 2
      return Plan.new(
        cla_id: @cla.id,
        action: :skip,
        groups: groups,
        primary_ott_id: typed.keys.first,
        primary_cot_ids: typed.values.first || cot_ids,
        creates: [],
        unresolved_cot_ids: unresolved,
        message: typed.empty? ? 'no_unique_typed_groups' : 'single_annotation_type'
      )
    end

    primary_ott_id = if @cla.ontology_term_type_id.present? && typed.key?(@cla.ontology_term_type_id)
                       @cla.ontology_term_type_id
                     else
                       typed.keys.min
                     end
    primary_cot_ids = typed[primary_ott_id]
    creates = typed.reject { |ott_id, _| ott_id == primary_ott_id }.map do |ott_id, ids|
      CreateSpec.new(ontology_term_type_id: ott_id, cot_ids: ids)
    end
    if unresolved.any?
      creates << CreateSpec.new(ontology_term_type_id: nil, cot_ids: unresolved)
    end

    Plan.new(
      cla_id: @cla.id,
      action: :split,
      groups: groups,
      primary_ott_id: primary_ott_id,
      primary_cot_ids: primary_cot_ids,
      creates: creates,
      unresolved_cot_ids: unresolved,
      message: "split_into_#{1 + creates.size}_clas"
    )
  end

  def apply!(dry_run: true)
    split_plan = plan
    return { plan: split_plan, updated: nil, created: [] } if split_plan.action != :split

    if dry_run
      return { plan: split_plan, updated: nil, created: [] }
    end

    created = []
    ActiveRecord::Base.transaction do
      @cla.update!(
        cell_ontology_term_ids: format_ids(split_plan.primary_cot_ids),
        sorted_cell_ontology_term_ids: format_sorted_ids(split_plan.primary_cot_ids),
        ontology_term_type_id: split_plan.primary_ott_id
      )

      split_plan.creates.each do |spec|
        attrs = split_attrs_from_original(spec)
        new_cla = Cla.create!(attrs)
        created << new_cla
      end
    end

    { plan: split_plan, updated: @cla, created: created }
  end

  private

  def format_ids(ids)
    Array(ids).map(&:to_i).join(',')
  end

  def format_sorted_ids(ids)
    Array(ids).map(&:to_i).sort.join(',')
  end

  def split_attrs_from_original(spec)
    {
      annot_id: @cla.annot_id,
      project_id: @cla.project_id,
      cell_set_id: @cla.cell_set_id,
      cla_source_id: @cla.cla_source_id,
      user_id: @cla.user_id,
      orcid_user_id: @cla.orcid_user_id,
      cat: @cla.cat,
      cat_idx: @cla.cat_idx,
      num: @cla.num,
      name: @cla.name,
      comment: @cla.comment,
      clone_id: @cla.id,
      obsolete: false,
      nber_agree: 0,
      nber_disagree: 0,
      cell_ontology_term_ids: format_ids(spec.cot_ids),
      sorted_cell_ontology_term_ids: format_sorted_ids(spec.cot_ids),
      ontology_term_type_id: spec.ontology_term_type_id,
      up_gene_ids: @cla.up_gene_ids,
      down_gene_ids: @cla.down_gene_ids,
      sorted_up_gene_ids: @cla.sorted_up_gene_ids,
      sorted_down_gene_ids: @cla.sorted_down_gene_ids
    }
  end
end
