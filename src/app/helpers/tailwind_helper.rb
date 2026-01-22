module TailwindHelper

  def tw_btn(type = :primary)
    h = {
      primary: "btn btn-primary",
      secondary: "btn btn-secondary",
      success: "btn btn-success",
      warning: "btn btn-warning",
      danger: "btn btn-danger",
      info: "btn btn-info",
      light: "btn btn-light",
      dark: "btn btn-dark"
    }
    
    return h[type]
  end

  def tw_menu_item(type = :default)
    h = {
      default: "menu-item menu-item-default",
      dropdown_item: "menu-item menu-item-dropdown"
    }
    
    return h[type]
  end

  # Bootstrap to Tailwind class translation hash
  def bootstrap_to_tailwind
    {
      # Card components - matching the new implementation paragraph style with borders
      'card' => 'bg-white border border-gray-200 rounded-lg shadow-sm pt-4 relative w-full h-full flex flex-col',
      'card-header' => 'text-sm font-semibold text-gray-700 uppercase tracking-wide mb-3 flex items-center gap-2 px-4',
      'card-body' => 'space-y-4 px-4 pb-4 flex-1',
      'card-text' => 'text-gray-700 mb-0',
      'card-title' => 'text-lg font-semibold text-gray-900 mb-2',
      
      # Badge components
      'badge' => 'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium',
      'badge-light' => 'bg-gray-100 text-gray-700 border border-gray-200',
      'badge-primary' => 'bg-blue-100 text-blue-700 border border-blue-200',
      'badge-secondary' => 'bg-gray-100 text-gray-700 border border-gray-200',
      'badge-success' => 'bg-green-100 text-green-700 border border-green-200',
      'badge-warning' => 'bg-yellow-100 text-yellow-700 border border-yellow-200',
      'badge-danger' => 'bg-red-100 text-red-700 border border-red-200',
      'badge-info' => 'bg-blue-100 text-blue-700 border border-blue-200',
      'badge-dark' => 'bg-gray-800 text-white border border-gray-900',
      
      # Grid system - using gap instead of negative margins, full width cards
      'row' => 'flex flex-wrap gap-4 w-full items-stretch',
      'col-md-12' => 'w-full flex-[1_1_100%] min-w-full',
      'col-md-6' => 'w-full md:w-[calc(50%-0.5rem)] md:flex-[1_1_calc(50%-0.5rem)]',
      'col-md-4' => 'w-full md:w-[calc(33.333%-0.667rem)] md:flex-[1_1_calc(33.333%-0.667rem)]',
      'col-md-3' => 'w-full md:w-[calc(25%-0.75rem)] md:flex-[1_1_calc(25%-0.75rem)]',
      'col-12' => 'w-full flex-[1_1_100%] min-w-full',
      'col' => 'flex-1',
      
      # Text utilities
      'text-muted' => 'text-gray-500',
      'text-danger' => 'text-red-600',
      'text-warning' => 'text-yellow-600',
      'text-success' => 'text-green-600',
      'text-info' => 'text-blue-600',
      'text-primary' => 'text-blue-600',
      'text-secondary' => 'text-gray-600',
      
      # Other utilities
      'text-truncate' => 'truncate',
      'text-wrap' => 'whitespace-normal',
      'nowrap' => 'whitespace-nowrap',
      'cursor-help' => 'cursor-help',
      'pointer' => 'cursor-pointer',
      'wrap' => 'flex-wrap'
    }
  end

  # Translate Bootstrap classes to Tailwind
  def tw_class(bootstrap_class)
    translation = bootstrap_to_tailwind
    classes = bootstrap_class.to_s.split(/\s+/)
    translated = classes.map do |cls|
      translation[cls] || cls
    end
    translated.join(' ')
  end

  # Translate Bootstrap classes in HTML content (for raw HTML from @h_el)
  def translate_bootstrap_in_html(html_content)
    return html_content unless html_content.is_a?(String)
    
    translation = bootstrap_to_tailwind
    result = html_content.dup
    
    # Translate class attributes
    translation.each do |bootstrap_class, tailwind_class|
      # Match class="..." or class='...' containing the bootstrap class
      result.gsub!(/class=["']([^"']*\b#{Regexp.escape(bootstrap_class)}\b[^"']*)["']/) do |match|
        classes = $1.split(/\s+/)
        translated_classes = classes.map { |cls| translation[cls] || cls }
        "class=\"#{translated_classes.join(' ')}\""
      end
    end
    
    result
  end
end
