namespace :annots do
  desc 'NULL synthetic or oversized headers_json (Value N lists / arrays larger than Annot::HEADERS_JSON_MAX_SIZE)'
  task null_synthetic_headers: :environment do
    max_size = Annot::HEADERS_JSON_MAX_SIZE

    synthetic_count = Annot.unscoped.where('headers_json LIKE ?', '["Value 1"%').count
    puts "Synthetic Value-N headers_json rows: #{synthetic_count}"

    # Single UPDATE — avoids loading TOAST into Ruby and is far faster than batched AR updates.
    synthetic_sql = <<~SQL.squish
      UPDATE annots
      SET headers_json = NULL,
          updated_at = NOW()
      WHERE headers_json LIKE '["Value 1"%'
    SQL
    synthetic_updated = ActiveRecord::Base.connection.exec_update(synthetic_sql)
    puts "Nulled synthetic Value-N headers_json: #{synthetic_updated}"

    oversized_sql = <<~SQL.squish
      UPDATE annots
      SET headers_json = NULL,
          updated_at = NOW()
      WHERE headers_json IS NOT NULL
        AND left(headers_json, 1) = '['
        AND jsonb_typeof(headers_json::jsonb) = 'array'
        AND jsonb_array_length(headers_json::jsonb) > #{max_size.to_i}
    SQL
    oversized_updated = ActiveRecord::Base.connection.exec_update(oversized_sql)
    puts "Nulled oversized header arrays (>#{max_size}): #{oversized_updated}"

    puts "Done. Total headers_json nulled: #{synthetic_updated.to_i + oversized_updated.to_i}"
  end
end
