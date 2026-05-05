# frozen_string_literal: true

# NCBI taxonomy nodes loaded from nodes.dmp + names.dmp (see ncbi_taxonomy:load_nodes).
# Seeds: distinct tax_id from latest asap_data.organisms plus all ancestors.
#
# order_tax_id: denormalized NCBI tax_id of the rank "order" ancestor (self if this row is an order).
#               nil when the lineage has no order node (e.g. ranks strictly above order).
#
# Two organism tax_ids are the same order when their order_tax_id matches (and both non-nil).
class NcbiTaxonomyNode < ApplicationRecord
  self.primary_key = :tax_id

  ORDER_RANK = "order"

  class << self
    def order_tax_id_for(tax_id)
      tax_id = tax_id.to_i
      return nil unless tax_id.positive?

      node = find_by(tax_id: tax_id)
      return nil unless node

      if has_order_tax_id_column?
        node.read_attribute(:order_tax_id)
      else
        order_tax_id_for_by_walk(tax_id)
      end
    end

    def order_tax_id_for_by_walk(tax_id)
      seen = Set.new
      current = tax_id.to_i
      while current.positive?
        break if seen.include?(current)

        seen << current
        node = find_by(tax_id: current)
        return nil unless node

        return current if node.rank.to_s == ORDER_RANK

        parent = node.parent_tax_id
        break if parent.nil? || parent == current

        current = parent
      end
      nil
    end

    def same_order?(tax_id_a, tax_id_b)
      a = find_by(tax_id: tax_id_a.to_i)
      b = find_by(tax_id: tax_id_b.to_i)
      return false unless a && b

      if has_order_tax_id_column?
        return false if a.read_attribute(:order_tax_id).nil? || b.read_attribute(:order_tax_id).nil?

        return a.read_attribute(:order_tax_id) == b.read_attribute(:order_tax_id)
      end

      oa = order_tax_id_for_by_walk(tax_id_a)
      ob = order_tax_id_for_by_walk(tax_id_b)
      oa.present? && oa == ob
    end

    def has_order_tax_id_column?
      column_names.include?("order_tax_id")
    end
  end
end
