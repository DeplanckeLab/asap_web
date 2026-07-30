module RunsHelper
  # Format scientific-notation values as "1.23×10<sup>-5</sup>" (2 decimal places max).
  # Non-scientific values are returned unchanged (plain text / SafeBuffer).
  def format_de_table_value(value)
    s = value.to_s.strip
    return s if s.blank?

    unless s.match?(/\A[+-]?\d+(?:\.\d+)?[eE][+-]?\d+\z/)
      return s
    end

    num = Float(s)
    return '0' if num.zero?

    sci = format('%.2e', num)
    m = sci.match(/\A([+-]?\d+\.\d+)e([+-]?\d+)\z/i)
    return s unless m

    coeff = m[1]
    coeff = coeff.sub(/\.?0+\z/, '') if coeff.include?('.')
    exp = m[2].to_i.to_s
    safe_join([
      coeff,
      '×10',
      content_tag(:sup, exp, style: 'font-size: 0.9em; vertical-align: super; line-height: 0;')
    ])
  rescue ArgumentError, TypeError
    s
  end
end
