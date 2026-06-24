# frozen_string_literal: true

module Scfair
  # Facade for versioned scFAIR rules bundles. Use Rules.for(schema_id) when the
  # schema is known; module-level methods use the current bundle (thread-local
  # during validation/fix) or the default release.
  module Rules
    DEFAULT_SCHEMA_ID = RulesRegistry::DEFAULT_SCHEMA_ID
    CF8_RULE_KEY = 'CF-8'
    CF9_RULE_KEY = 'CF-9'
    DEFAULT_CHECK_FORMATS = %w[h5ad loom].freeze
    PRESENCE_CHECK_IDS = RulesBundle::PRESENCE_CHECK_IDS
    ONTOLOGY_FORMAT_CHECK_ID = RulesBundle::ONTOLOGY_FORMAT_CHECK_ID

    class << self
      def for(schema_id = nil)
        RulesRegistry.bundle(schema_id)
      end

      def current_bundle
        Thread.current[:scfair_rules_bundle] || self.for(DEFAULT_SCHEMA_ID)
      end

      def with_bundle(schema_id)
        previous = Thread.current[:scfair_rules_bundle]
        Thread.current[:scfair_rules_bundle] = self.for(schema_id)
        yield
      ensure
        Thread.current[:scfair_rules_bundle] = previous
      end

      def available_schemas
        RulesRegistry.available_schemas
      end

      def reload!
        RulesRegistry.reload!
      end

      def schema_config(schema_id = DEFAULT_SCHEMA_ID)
        self.for(schema_id).schema_config
      end

      def method_missing(method_name, *args, **kwargs, &block)
        if current_bundle.respond_to?(method_name)
          return current_bundle.public_send(method_name, *args, **kwargs, &block)
        end

        super
      end

      def respond_to_missing?(method_name, include_private = false)
        current_bundle.respond_to?(method_name, include_private) || super
      end
    end
  end
end
