class OrganismsController < ApplicationController
  before_action :authenticate_user!

  def index
    @remote_versions = RemoteOrganism.remote_versions
    @selected_source = selected_source

    @organisms, @source_label, @error = fetch_organisms(@selected_source)
  end

  private

  def selected_source
    requested = params[:db_version].presence
    return :local unless admin? && requested

    normalized = requested.to_s
    RemoteOrganism.remote_versions.include?(normalized) ? normalized : :local
  end

  def fetch_organisms(source)
    if source == :local
      [Organism.order(:name), "Local database", nil]
    else
      organisms = RemoteOrganism.list_for_version(source)
      label = source.sub(/^asap2_data_/, "").upcase
      [organisms, "Remote #{label}", nil]
    end
  rescue StandardError => e
    Rails.logger.error("[OrganismsController] #{source}: #{e.class} - #{e.message}")
    [[], source_label_for(source), e.message]
  end

  def source_label_for(source)
    return "Local database" if source == :local
    "Remote #{source.sub(/^asap2_data_/, "").upcase}"
  end
end

