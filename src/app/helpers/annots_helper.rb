# frozen_string_literal: true

module AnnotsHelper
  DOWNLOAD_LINK_CLASS = 'inline-flex items-center px-2 py-1 text-xs font-medium text-gray-600 bg-white border border-gray-300 rounded hover:bg-gray-50 hover:text-gray-900 transition-colors'

  def annot_download_links(annot, wrapper_class: 'flex items-center gap-1')
    return ''.html_safe if annot.expression_matrix?

    content_tag(
      :div,
      class: wrapper_class,
      data: {
        controller: 'annot-download'
      }
    ) do
      safe_join(
        [
          annot_download_link(annot, 'tsv.gz', 'TSV', 'Download as TSV.gz'),
          annot_download_link(annot, 'json', 'JSON', 'Download as JSON')
        ]
      )
    end
  end

  def annot_download_link(annot, format_type, label, title)
    link_to download_annot_path(annot, format_type: format_type),
            class: DOWNLOAD_LINK_CLASS,
            title: title,
            rel: 'nofollow',
            data: {
              turbo: false,
              action: 'click->annot-download#start'
            } do
      safe_join(
        [
          content_tag(:i, nil, class: 'fas fa-download mr-1'),
          label
        ]
      )
    end
  end

  # Recursively render a JSON value as nested foldable <details> blocks.
  def render_json_foldable(value, key: nil, depth: 0, open: false)
    if value.is_a?(Hash)
      render_json_foldable_object(value, key: key, depth: depth, open: open)
    elsif value.is_a?(Array)
      render_json_foldable_array(value, key: key, depth: depth, open: open)
    else
      render_json_foldable_scalar(value, key: key)
    end
  end

  private

  def render_json_foldable_object(hash, key:, depth:, open:)
    summary = json_foldable_summary(key, "{#{hash.size} #{'key'.pluralize(hash.size)}}")
    content_tag(:details, class: 'json-foldable my-0.5', open: (open || depth.zero?) ? true : nil) do
      safe_join(
        [
          content_tag(:summary, summary, class: 'cursor-pointer select-none text-gray-800 py-0.5'),
          content_tag(:div, class: 'ml-4 border-l border-gray-200 pl-3') do
            if hash.empty?
              content_tag(:div, '{}', class: 'text-xs text-gray-400 font-mono py-0.5')
            else
              safe_join(
                hash.map do |child_key, child_value|
                  render_json_foldable(child_value, key: child_key.to_s, depth: depth + 1, open: false)
                end
              )
            end
          end
        ]
      )
    end
  end

  def render_json_foldable_array(array, key:, depth:, open:)
    summary = json_foldable_summary(key, "[#{array.size} #{'item'.pluralize(array.size)}]")
    content_tag(:details, class: 'json-foldable my-0.5', open: (open || depth.zero?) ? true : nil) do
      safe_join(
        [
          content_tag(:summary, summary, class: 'cursor-pointer select-none text-gray-800 py-0.5'),
          content_tag(:div, class: 'ml-4 border-l border-gray-200 pl-3') do
            if array.empty?
              content_tag(:div, '[]', class: 'text-xs text-gray-400 font-mono py-0.5')
            else
              safe_join(
                array.each_with_index.map do |child_value, index|
                  render_json_foldable(child_value, key: index.to_s, depth: depth + 1, open: false)
                end
              )
            end
          end
        ]
      )
    end
  end

  def render_json_foldable_scalar(value, key:)
    content_tag(:div, class: 'py-0.5 text-xs font-mono break-all') do
      if key
        safe_join(
          [
            content_tag(:span, "#{key}: ", class: 'text-gray-600'),
            content_tag(:span, json_scalar_display(value), class: json_scalar_class(value))
          ]
        )
      else
        content_tag(:span, json_scalar_display(value), class: json_scalar_class(value))
      end
    end
  end

  def json_foldable_summary(key, type_label)
    if key
      safe_join(
        [
          content_tag(:span, "#{key}: ", class: 'text-gray-700 font-medium'),
          content_tag(:span, type_label, class: 'text-gray-500 text-xs font-mono')
        ]
      )
    else
      content_tag(:span, type_label, class: 'text-gray-700 font-medium text-xs font-mono')
    end
  end

  def json_scalar_display(value)
    case value
    when NilClass then 'null'
    when TrueClass, FalseClass then value.to_s
    when Numeric then value.to_s
    else value.to_s.inspect
    end
  end

  def json_scalar_class(value)
    case value
    when NilClass then 'text-gray-400'
    when TrueClass, FalseClass then 'text-amber-700'
    when Numeric then 'text-blue-700'
    else 'text-gray-900'
    end
  end
end
