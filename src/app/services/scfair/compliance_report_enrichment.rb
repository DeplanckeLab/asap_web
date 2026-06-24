# frozen_string_literal: true

module Scfair
  # Enriches compliance validation items with check details and optional field values.
  module ComplianceReportEnrichment
    PRESENCE_VALUE_CATEGORIES = %w[uns.required_presence obs.required_presence var.required].freeze

  private

    def enrich_with_details(result)
      format = result[:format]
      field_values = result[:field_values] || {}
      result[:errors] = enrich_items(result[:errors], format, field_values)
      result[:warnings] = enrich_items(result[:warnings], format, field_values)
      result[:check_groups] = Array(result[:check_groups]).map do |group|
        category_id = group[:id] || group['id']
        items = Array(group[:items] || group['items']).map do |item|
          item = CheckDetailBuilder.enrich_item(item, format: format, category_id: category_id, field_values: field_values)
          attach_field_values(item, field_values, category_id)
        end
        group.merge(items: items)
      end
      result
    end

    def enrich_items(items, format, field_values = {})
      Array(items).map do |item|
        enriched = CheckDetailBuilder.enrich_item(item, format: format, field_values: field_values)
        attach_field_values(enriched, field_values, ComplianceReportGrouper.category_for(
          field: enriched[:field] || enriched['field'],
          message: enriched[:message] || enriched['message'],
          format: format
        ))
      end
    end

    def attach_field_values(item, field_values, category_id)
      return item unless show_field_values?(item, category_id)

      field = (item[:field] || item['field']).to_s
      values = lookup_field_values(field_values, field)
      return item if values.blank?

      item.merge(values: values)
    end

    def show_field_values?(item, category_id)
      id = category_id.to_s
      return false unless PRESENCE_VALUE_CATEGORIES.include?(id)

      status = (item[:status] || item['status']).to_s
      return false if status == 'failed'

      check_id = (item[:check_id] || item['check_id']).to_s
      return Rules.presence_check_id?(check_id) if check_id.present?

      CheckDetailBuilder.presence_check_message?(item[:message] || item['message'])
    end

    def lookup_field_values(field_values, field)
      raw = field_values[field] || field_values[field.to_sym]
      Array(raw).map(&:to_s).map(&:strip).reject(&:blank?).presence
    end
  end
end
