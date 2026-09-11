# frozen_string_literal: true

class ExternalCatalogImportChannel < ApplicationCable::Channel
  def subscribed
    candidate_id = params[:candidate_id].to_i
    if candidate_id.positive?
      stream_from ExternalCatalog::ImportProgress.stream_name(candidate_id)
      snapshot = ExternalCatalog::ImportProgress.read(candidate_id)
      transmit(snapshot) if snapshot.present?
    else
      reject
    end
  end

  def unsubscribed
    # no-op
  end
end
