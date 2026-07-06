# frozen_string_literal: true

# Normalizes heatmap_meta.json payloads for API responses.
#
# Early heatmap runs stored dendrograms as deeply nested JSON (one level per
# merge). That breaks Ruby's default JSON nesting limit (100) when the endpoint
# re-serializes the metadata. New runs use a flat linkage ({ n_leaves, merges }).
# This converts legacy nested trees to flat form when serving old results.
class HeatmapMetaNormalizer
  def self.normalize!(meta)
    return meta unless meta.is_a?(Hash)

    normalize_tree!(meta, "col_tree", meta["n_cols"].to_i)
    normalize_tree!(meta, "row_tree", meta["n_rows"].to_i)
    meta
  end

  def self.normalize_tree!(meta, key, n_leaves)
    tree = meta[key]
    return if tree.nil?
    return if flat_tree?(tree)

    meta[key] = nested_tree_to_flat(tree, n_leaves) if tree.is_a?(Hash)
  end

  def self.flat_tree?(tree)
    tree.is_a?(Hash) && tree["merges"].is_a?(Array)
  end

  def self.nested_tree_to_flat(node, n_leaves)
    merges = []

    convert = lambda do |nd|
      if nd["leaf"]
        return nd["index"].to_i
      end

      children = Array(nd["children"])
      left_id = convert.call(children[0])
      right_id = convert.call(children[1])
      id = n_leaves + merges.length
      merges << [left_id, right_id, nd["height"].to_f]
      id
    end

    convert.call(node)
    { "n_leaves" => n_leaves, "merges" => merges }
  end

  private_class_method :normalize_tree!, :flat_tree?, :nested_tree_to_flat
end
