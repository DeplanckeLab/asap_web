# frozen_string_literal: true

module ExternalCatalog
  # Upserts Provider rows (catalog resource origins) from a development snapshot.
  # Matched by +tag+ (same key as ExternalCatalogCandidate#provider_tag).
  # Does not force source primary keys (ProviderProject FKs stay local).
  # Does not delete target-only providers.
  class ProviderDevSync
    ATTR_KEYS = %w[name description tag url url_mask attrs_json].freeze

    def self.prepare_row(attrs)
      h = attrs.stringify_keys
      {
        name: h['name'],
        description: h['description'],
        tag: h['tag'].to_s,
        url: h['url'],
        url_mask: h['url_mask'],
        attrs_json: h['attrs_json'].presence || '{}'
      }
    end

    # Returns :created, :updated, or :unchanged
    def self.apply_row!(row)
      prepared = row.is_a?(Hash) && row.key?(:tag) ? row : prepare_row(row)
      tag = prepared[:tag].to_s.strip
      raise ArgumentError, "Provider row missing tag: #{prepared.inspect}" if tag.blank?

      record = Provider.find_by(tag: tag)
      attrs = {
        name: prepared[:name],
        description: prepared[:description],
        url: prepared[:url],
        url_mask: prepared[:url_mask],
        attrs_json: prepared[:attrs_json].presence || '{}'
      }

      if record.nil?
        Provider.create!(attrs.merge(tag: tag))
        return :created
      end

      changes = attrs.select { |key, value| normalize_attr(record.public_send(key)) != normalize_attr(value) }
      return :unchanged if changes.empty?

      record.update!(changes)
      :updated
    end

    def self.normalize_attr(value)
      value.nil? ? nil : value.to_s
    end
    private_class_method :normalize_attr
  end
end
