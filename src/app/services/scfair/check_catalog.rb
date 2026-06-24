# frozen_string_literal: true

module Scfair
  # Shared check definitions for standalone and project validators.
  module CheckCatalog
    module_function

    def available_schemas
      Rules.available_schemas
    end

    def schema!(schema_id)
      bundle = Rules.for(schema_id)
      hash = bundle.schema_hash
      {
        id: hash[:id],
        label: hash[:label],
        schema_version: bundle.schema_version,
        source_url: hash[:source_url]
      }
    end

    def checks_for(format, schema_id: nil)
      Rules.for(schema_id).checks_for(format)
    end
  end
end
