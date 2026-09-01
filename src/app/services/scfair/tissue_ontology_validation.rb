# frozen_string_literal: true

module Scfair
  # scFAIR tissue_ontology_term_id rules depend on obs/tissue_type:
  # - tissue / organoid: UBERON (or taxon anatomy prefixes)
  # - cell line: Cellosaurus CVCL_*
  # - primary cell culture: CL (or taxon cell-type prefixes)
  module TissueOntologyValidation
    FIELD = 'tissue_ontology_term_id'

    module_function

    def field?(field_name)
      field_name.to_s == FIELD
    end

    def tissue_type_from(field_values, format)
      path = Rules.field_path(format.to_s, :obs, 'tissue_type')
      first_value(field_values, path)
    end

    def organism_from(field_values, format)
      uns_path = Rules.field_path(format.to_s, :uns, 'organism_ontology_term_id')
      obs_path = Rules.field_path(format.to_s, :obs, 'organism_ontology_term_id')
      first_value(field_values, uns_path) || first_value(field_values, obs_path)
    end

    def format_prefixes(tissue_type:, organism:, default_prefixes:)
      cfg = Rules.organism_specific_validation_config
      case tissue_type.to_s
      when cfg[:cell_line_tissue_type]
        [Rules.cellosaurus_ontology_tag]
      when cfg[:primary_cell_culture_tissue_type]
        organism.present? ? Rules.organism_cell_type_prefixes_for(organism) : Rules.organism_cell_type_default_prefixes
      when '', nil
        Array(default_prefixes)
      else
        organism.present? ? Rules.organism_tissue_prefixes_for(organism) : Array(default_prefixes)
      end
    end

    def semantic_rules(tissue_type:)
      cfg = Rules.organism_specific_validation_config
      if tissue_type.to_s == cfg[:primary_cell_culture_tissue_type]
        OntologySemanticRules.rules_for('cell_type_ontology_term_id')
      else
        OntologySemanticRules.rules_for(FIELD)
      end
    end

    def first_value(field_values, path)
      Array(field_values[path] || field_values[path.to_sym]).map(&:to_s).reject(&:blank?).first
    end
  end
end
