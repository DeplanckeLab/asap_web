# frozen_string_literal: true

module Scfair
  # Shared check definitions for standalone and project validators.
  module CheckCatalog
    module_function

    def available_schemas
      [Rules.schema_hash]
    end

    def schema!(schema_id)
      Rules.schema_config(schema_id)
    end

    def checks_for(format)
      Rules.checks_for(format)
    end
  end
end
