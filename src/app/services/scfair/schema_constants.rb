# frozen_string_literal: true

module Scfair
  module SchemaConstants
    VALID_SEX_TERM_IDS = Rules.valid_sex_terms.freeze
    SEX_SPECIAL_VALUES = Rules.sex_special_values
    BANNED_CELL_TYPE_TERMS = Rules.banned_cell_type_terms
    VISIUM_ASSAY_ROOT = 'EFO:0010961'
    VISIUM_ASSAY_TERMS = Rules.visium_assay_terms
    SLIDE_SEQ_ASSAY = Rules.slide_seq_assay
  end
end
