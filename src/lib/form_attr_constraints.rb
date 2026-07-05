# frozen_string_literal: true

# Canonical required/optional rules for std form attributes:
# - input_data: min_nber_items 0 = optional, >= 1 = required (primary signal)
# - scalars (textfield, select, ...): not_null true = required
# - optional key is deprecated; still read for backward compatibility during migration
module FormAttrConstraints
  AUTO_FILLED_REQUIRED_ATTRS = %w[group_ref group_comp].freeze

  module_function

  def input_data?(attr)
    attr.is_a?(Hash) && attr["widget"].to_s == "input_data"
  end

  def legacy_optional_true?(attr)
    attr.key?("optional") && ActiveModel::Type::Boolean.new.cast(attr["optional"])
  end

  def legacy_optional_false?(attr)
    attr.key?("optional") && !ActiveModel::Type::Boolean.new.cast(attr["optional"])
  end

  # Whether an input_data attr should not gate method/step availability.
  def input_data_optional?(attr_config)
    return false unless attr_config.is_a?(Hash)
    return false unless input_data?(attr_config)

    if attr_config.key?("min_nber_items")
      return attr_config["min_nber_items"].to_i.zero?
    end

    return true if legacy_optional_true?(attr_config)
    return false if legacy_optional_false?(attr_config)

    if attr_config.key?("not_null")
      return !ActiveModel::Type::Boolean.new.cast(attr_config["not_null"])
    end

    false
  end

  def optional?(attr_name, attr)
    return false unless attr.is_a?(Hash)
    return false if required?(attr_name, attr)

    if input_data?(attr)
      return input_data_optional?(attr)
    end

    !ActiveModel::Type::Boolean.new.cast(attr["not_null"])
  end

  def required?(attr_name, attr)
    return false unless attr.is_a?(Hash)
    return false if AUTO_FILLED_REQUIRED_ATTRS.include?(attr_name.to_s)

    if input_data?(attr)
      if attr.key?("min_nber_items")
        return attr["min_nber_items"].to_i.positive?
      end
      return true if ActiveModel::Type::Boolean.new.cast(attr["not_null"])
      return true if legacy_optional_false?(attr)
      return false
    end

    ActiveModel::Type::Boolean.new.cast(attr["not_null"])
  end

  # Migrate deprecated optional to not_null / min_nber_items. Returns a new hash.
  def migrate_attr!(attr)
    return attr unless attr.is_a?(Hash) && attr.key?("optional")

    optional = ActiveModel::Type::Boolean.new.cast(attr["optional"])
    migrated = attr.dup
    migrated.delete("optional")

    if input_data?(migrated)
      if optional
        migrated["min_nber_items"] = 0 unless migrated.key?("min_nber_items") && migrated["min_nber_items"].to_i.positive?
      elsif !migrated.key?("min_nber_items")
        migrated["min_nber_items"] = 1
      end
    elsif !migrated.key?("not_null")
      migrated["not_null"] = !optional
    end

    migrated
  end

  def migrate_attrs_hash!(attrs_hash)
    return attrs_hash unless attrs_hash.is_a?(Hash)

    attrs_hash.transform_values { |attr| migrate_attr!(attr) }
  end
end
