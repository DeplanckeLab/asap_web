class RemoteOrganism < Asap2RemoteRecord
  self.table_name = "organisms"

  DISPLAY_ATTRIBUTES = %w[id name short_name created_at updated_at].freeze

  def self.list_for_version(version)
    with_remote(version) do
      order(:name).map do |organism|
        organism.attributes.slice(*DISPLAY_ATTRIBUTES)
      end
    end
  end
end

