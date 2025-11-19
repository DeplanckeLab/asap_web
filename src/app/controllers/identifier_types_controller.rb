class IdentifierTypesController < ApplicationController
  before_action :set_identifier_type, only: :show

  def show
    @exp_entries = @identifier_type.exp_entries.order(:identifier)
    @exp_entry_identifiers = ExpEntryIdentifier.for_type(@identifier_type.id)
                                              .includes(:exp_entry)
                                              .order(:identifier)
    @exp_entries_map = @exp_entry_identifiers.map(&:exp_entry).compact.index_by(&:id)
  end

  private

  def set_identifier_type
    @identifier_type = IdentifierType.find(params[:id])
  end
end

