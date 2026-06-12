# frozen_string_literal: true

module Scfair
  class OntologyLineageResolver
    def initialize
      @terms_by_identifier = {}
    end

    def register(identifier)
      return if identifier.blank? || @terms_by_identifier.key?(identifier)
      @terms_by_identifier[identifier] = CellOntologyTerm.active_original_by_identifier(identifier)
    end

    def exists?(identifier)
      register(identifier)
      @terms_by_identifier[identifier].present?
    end

    def descendant_of?(identifier, root_identifier)
      register(identifier)
      register(root_identifier)
      term = @terms_by_identifier[identifier]
      root = @terms_by_identifier[root_identifier]
      return false if term.nil? || root.nil?
      return true if term.id == root.id
      term.lineage.to_s.split(',').include?(root.id.to_s)
    end
  end
end
