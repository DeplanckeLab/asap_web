# frozen_string_literal: true

module Scfair
  module SchemaConstants
    VALID_SEX_TERM_IDS = {
      'PATO:0000383' => 'female',
      'PATO:0000384' => 'male',
      'PATO:0001340' => 'hermaphrodite',
      'PATO:0001894' => 'intersex'
    }.freeze

    SEX_SPECIAL_VALUES = %w[unknown na].freeze
    BANNED_CELL_TYPE_TERMS = %w[CL:0000003 CL:0000255 CL:0000548 CL:0001035].freeze

    VISIUM_ASSAY_ROOT = 'EFO:0010961'
    VISIUM_ASSAY_TERMS = %w[EFO:0010961 EFO:0022857 EFO:0022859 EFO:0022860].freeze
    SLIDE_SEQ_ASSAY = 'EFO:0030062'
  end
end
