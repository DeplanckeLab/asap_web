class RemapNewsItemTypesAndIcons < ActiveRecord::Migration[8.1]
  OLD_DEFAULT_ICONS = {
    'feature' => 'fas fa-rocket',
    'update' => 'fas fa-bolt'
  }.freeze

  NEW_DEFAULT_ICONS = {
    'release' => 'fas fa-rocket',
    'feature' => 'fas fa-bolt',
    'announcement' => 'fas fa-bullhorn',
    'alert' => 'fas fa-fire',
    'tip' => 'fas fa-lightbulb'
  }.freeze

  class NewsItemRecord < ActiveRecord::Base
    self.table_name = 'news_items'
  end

  def up
    NewsItemRecord.where(news_type: 'update').find_each do |item|
      item.update_columns(
        news_type: 'feature',
        icon: item.icon == OLD_DEFAULT_ICONS['update'] ? NEW_DEFAULT_ICONS['feature'] : item.icon
      )
    end

    NewsItemRecord.where(news_type: 'feature', icon: OLD_DEFAULT_ICONS['feature']).update_all(
      icon: NEW_DEFAULT_ICONS['feature']
    )
  end

  def down
    NewsItemRecord.where(news_type: 'feature', icon: NEW_DEFAULT_ICONS['feature']).update_all(
      icon: OLD_DEFAULT_ICONS['feature']
    )
  end
end
