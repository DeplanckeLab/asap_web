module NewsItemsHelper
  def news_item_card_classes(news_item)
    scheme = news_item.color_scheme
    "rounded-lg border #{scheme[:border]} #{scheme[:bg]} px-4 py-3 text-left shadow-sm"
  end

  def news_item_icon_tag(news_item, size_class: 'text-lg')
    content_tag(
      :i,
      nil,
      class: "#{news_item.icon} #{size_class} #{news_item.color_scheme[:icon]}",
      'aria-hidden': true
    )
  end

  def news_item_type_badge(news_item)
    scheme = news_item.color_scheme
    content_tag(
      :span,
      news_item.type_label,
      class: "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold #{scheme[:badge_bg]} #{scheme[:badge_text]}"
    )
  end

  # Explicit Tailwind class strings so the build picks up highlight rings.
  def news_item_highlight_ring_class(news_item)
    {
      'blue' => 'ring-blue-400 dark:ring-blue-300',
      'amber' => 'ring-amber-400 dark:ring-amber-300',
      'purple' => 'ring-purple-400 dark:ring-purple-300',
      'emerald' => 'ring-emerald-400 dark:ring-emerald-300',
      'sky' => 'ring-sky-400 dark:ring-sky-300',
      'rose' => 'ring-rose-400 dark:ring-rose-300'
    }.fetch(news_item.color_key, 'ring-gray-400 dark:ring-gray-300')
  end

  def format_news_published_at(news_item)
    news_item.published_at.strftime('%B %-d, %Y')
  end
end
