# frozen_string_literal: true

module PerturbTestHelpers
  def perturb_field_values(format:, perturbation_id: 'guide_a', strategy: 'CRISPR knockout screen',
                           organism: 'NCBITaxon:9606', role: 'targeting',
                           protospacer: 'ACGTACGTACGTACGTACGT', pam: "3' NGG")
    obs_prefix = format == 'h5ad' ? 'obs' : '/col_attrs'
    uns_prefix = format == 'h5ad' ? 'uns/genetic_perturbations' : '/attrs/genetic_perturbations'
    organism_key = format == 'h5ad' ? 'uns/organism_ontology_term_id' : '/attrs/organism_ontology_term_id'

    {
      organism_key => [organism],
      "#{obs_prefix}/genetic_perturbation_id" => [perturbation_id],
      "#{obs_prefix}/genetic_perturbation_strategy" => [strategy],
      "#{uns_prefix}/#{perturbation_id}/role" => [role],
      "#{uns_prefix}/#{perturbation_id}/protospacer_sequence" => [protospacer],
      "#{uns_prefix}/#{perturbation_id}/protospacer_adjacent_motif" => [pam]
    }
  end
end
