# frozen_string_literal: true

# Tables renamed in the past kept the id sequence of their old name (fus -> courses_id_seq,
# exp_entries -> geo_entries_id_seq, ...). db/schema.rb then references sequences it never creates,
# so it cannot be loaded into an empty database. Give each table its own <table>_id_seq, owned by
# its id column. Renaming keeps the current value; column defaults follow the sequence by OID.
class RenameLegacyPrimaryKeySequences < ActiveRecord::Migration[7.2]
  TABLES = %w[ensembl_subdomains_old exp_entries filter_methods fus gene_filterings provider_projects].freeze

  def up
    TABLES.each do |table|
      next unless table_exists?(table)

      current = id_default_sequence(table)
      target = "#{table}_id_seq"
      next if current.nil? || current == target

      if sequence_exists?(target)
        say "#{table}: #{target} already exists, keeping #{current}"
        next
      end

      if sequence_used_by_other_table?(current, table)
        # Shared with another table (e.g. a schema.rb-loaded database where ensembl_subdomains and
        # ensembl_subdomains_old both use ensembl_subdomains_id_seq): give this table a new sequence.
        execute "CREATE SEQUENCE #{connection.quote_table_name(target)}"
        execute "SELECT setval(#{connection.quote(target)}, COALESCE((SELECT MAX(id) FROM #{connection.quote_table_name(table)}), 0) + 1, false)"
        execute "ALTER TABLE #{connection.quote_table_name(table)} ALTER COLUMN id SET DEFAULT nextval(#{connection.quote(target)}::regclass)"
        say "#{table}: #{current} is shared, created #{target}"
      else
        execute "ALTER SEQUENCE #{connection.quote_table_name(current)} RENAME TO #{connection.quote_table_name(target)}"
        say "#{table}: renamed #{current} to #{target}"
      end
      execute "ALTER SEQUENCE #{connection.quote_table_name(target)} OWNED BY #{connection.quote_table_name(table)}.id"
    end
  end

  def down
    # Sequence names carry no data; the renamed sequences keep working.
  end

  private

  # Name of the sequence in the id column default, e.g. "courses_id_seq" (nil if none).
  def id_default_sequence(table)
    sequence_from_default(connection.select_value(<<~SQL.squish))
      SELECT pg_get_expr(d.adbin, d.adrelid)
      FROM pg_attrdef d
      JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
      WHERE d.adrelid = #{connection.quote(table)}::regclass AND a.attname = 'id'
    SQL
  end

  def sequence_from_default(expr)
    expr.to_s[/\Anextval\('"?(?:public\.)?([^'"]+)"?'::regclass\)\z/, 1]
  end

  def sequence_exists?(name)
    connection.select_value("SELECT to_regclass(#{connection.quote(name)})::text").present?
  end

  def sequence_used_by_other_table?(sequence, table)
    connection.select_values(<<~SQL.squish).any? { |expr| sequence_from_default(expr) == sequence }
      SELECT pg_get_expr(d.adbin, d.adrelid)
      FROM pg_attrdef d
      WHERE d.adrelid <> #{connection.quote(table)}::regclass
        AND pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%'
    SQL
  end
end
