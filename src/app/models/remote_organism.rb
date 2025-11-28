class RemoteOrganism < Asap2RemoteRecord
  self.table_name = "organisms"

  DISPLAY_ATTRIBUTES = %w[id name short_name tax_id ensembl_subdomain_id created_at updated_at].freeze

  def self.list_for_version(version)
    with_remote(version) do
      joins('LEFT JOIN ensembl_subdomains ON organisms.ensembl_subdomain_id = ensembl_subdomains.id')
        .select('organisms.*, ensembl_subdomains.name as domain_name')
        .order(:name)
        .map do |organism|
          attrs = organism.attributes.slice(*DISPLAY_ATTRIBUTES)
          attrs['domain_name'] = organism.read_attribute('domain_name')
          attrs
        end
    end
  end
end

