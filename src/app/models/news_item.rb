class NewsItem < ApplicationRecord
  belongs_to :user, optional: true

  NEWS_TYPES = {
    'release' => {
      label: 'New release',
      default_icon: 'fas fa-rocket',
      color: 'emerald'
    },
    'feature' => {
      label: 'Feature / Update',
      default_icon: 'fas fa-bolt',
      color: 'blue'
    },
    'fix' => {
      label: 'Fix',
      default_icon: 'fas fa-wrench',
      color: 'rose'
    },
    'announcement' => {
      label: 'Technical issue',
      default_icon: 'fas fa-bullhorn',
      color: 'purple'
    },
    'tip' => {
      label: 'Tip',
      default_icon: 'fas fa-lightbulb',
      color: 'sky'
    }
  }.freeze

  ICONS = [
    { value: 'fas fa-rocket', label: 'Rocket' },
    { value: 'fas fa-fire', label: 'Fire' },
    { value: 'fas fa-bullhorn', label: 'Loudspeaker' },
    { value: 'fas fa-bolt', label: 'Bolt' },
    { value: 'fas fa-star', label: 'Star' },
    { value: 'fas fa-info-circle', label: 'Info' },
    { value: 'fas fa-exclamation-triangle', label: 'Warning' },
    { value: 'fas fa-lightbulb', label: 'Lightbulb' },
    { value: 'fas fa-gift', label: 'Gift' },
    { value: 'fas fa-wrench', label: 'Wrench' },
    { value: 'fas fa-code-branch', label: 'Code branch' },
    { value: 'fas fa-newspaper', label: 'Newspaper' },
    { value: 'fas fa-check-circle', label: 'Check' },
    { value: 'fas fa-flask', label: 'Flask' }
  ].freeze

  COLOR_SCHEMES = {
    'blue' => {
      border: 'border-blue-200 dark:border-blue-500/30',
      bg: 'bg-blue-50 dark:bg-blue-500/10',
      title: 'text-blue-900 dark:text-blue-200',
      body: 'text-blue-800 dark:text-blue-300',
      icon: 'text-blue-600 dark:text-blue-400',
      badge_bg: 'bg-blue-100 dark:bg-blue-500/20',
      badge_text: 'text-blue-800 dark:text-blue-200',
      details: 'text-blue-700/70 dark:text-blue-300/70',
      highlight_ring: 'ring-blue-400 dark:ring-blue-300'
    },
    'amber' => {
      border: 'border-amber-200 dark:border-amber-500/30',
      bg: 'bg-amber-50 dark:bg-amber-500/10',
      title: 'text-amber-900 dark:text-amber-200',
      body: 'text-amber-800 dark:text-amber-300',
      icon: 'text-amber-600 dark:text-amber-400',
      badge_bg: 'bg-amber-100 dark:bg-amber-500/20',
      badge_text: 'text-amber-800 dark:text-amber-200',
      details: 'text-amber-700/70 dark:text-amber-300/70',
      highlight_ring: 'ring-amber-400 dark:ring-amber-300'
    },
    'purple' => {
      border: 'border-purple-200 dark:border-purple-500/30',
      bg: 'bg-purple-50 dark:bg-purple-500/10',
      title: 'text-purple-900 dark:text-purple-200',
      body: 'text-purple-800 dark:text-purple-300',
      icon: 'text-purple-600 dark:text-purple-400',
      badge_bg: 'bg-purple-100 dark:bg-purple-500/20',
      badge_text: 'text-purple-800 dark:text-purple-200',
      details: 'text-purple-700/70 dark:text-purple-300/70',
      highlight_ring: 'ring-purple-400 dark:ring-purple-300'
    },
    'emerald' => {
      border: 'border-emerald-200 dark:border-emerald-500/30',
      bg: 'bg-emerald-50 dark:bg-emerald-500/10',
      title: 'text-emerald-900 dark:text-emerald-200',
      body: 'text-emerald-800 dark:text-emerald-300',
      icon: 'text-emerald-600 dark:text-emerald-400',
      badge_bg: 'bg-emerald-100 dark:bg-emerald-500/20',
      badge_text: 'text-emerald-800 dark:text-emerald-200',
      details: 'text-emerald-700/70 dark:text-emerald-300/70',
      highlight_ring: 'ring-emerald-400 dark:ring-emerald-300'
    },
    'sky' => {
      border: 'border-sky-200 dark:border-sky-500/30',
      bg: 'bg-sky-50 dark:bg-sky-500/10',
      title: 'text-sky-900 dark:text-sky-200',
      body: 'text-sky-800 dark:text-sky-300',
      icon: 'text-sky-600 dark:text-sky-400',
      badge_bg: 'bg-sky-100 dark:bg-sky-500/20',
      badge_text: 'text-sky-800 dark:text-sky-200',
      details: 'text-sky-700/70 dark:text-sky-300/70',
      highlight_ring: 'ring-sky-400 dark:ring-sky-300'
    },
    'rose' => {
      border: 'border-rose-200 dark:border-rose-500/30',
      bg: 'bg-rose-50 dark:bg-rose-500/10',
      title: 'text-rose-900 dark:text-rose-200',
      body: 'text-rose-800 dark:text-rose-300',
      icon: 'text-rose-600 dark:text-rose-400',
      badge_bg: 'bg-rose-100 dark:bg-rose-500/20',
      badge_text: 'text-rose-800 dark:text-rose-200',
      details: 'text-rose-700/70 dark:text-rose-300/70',
      highlight_ring: 'ring-rose-400 dark:ring-rose-300'
    }
  }.freeze

  validates :title, presence: true
  validates :body, presence: true
  validates :news_type, presence: true, inclusion: { in: NEWS_TYPES.keys }
  validates :icon, presence: true, inclusion: { in: ICONS.map { |i| i[:value] } }
  validates :published_at, presence: true

  before_validation :apply_default_icon, on: :create
  before_validation :set_default_published_at

  scope :published, -> { where(published: true) }
  scope :for_welcome, -> { published.where(show_on_welcome: true) }
  scope :ordered, -> { order(published_at: :desc, id: :desc) }

  def github_synced?
    github_discussion_node_id.present? && github_discussion_url.present?
  end

  def github_syncable?
    NewsItems::GithubDiscussionSync.syncable?(self)
  end

  def type_label
    NEWS_TYPES.dig(news_type, :label) || news_type.to_s.humanize
  end

  def color_key
    NEWS_TYPES.dig(news_type, :color) || 'purple'
  end

  def color_scheme
    COLOR_SCHEMES.fetch(color_key)
  end

  def self.default_icon_for(type)
    NEWS_TYPES.dig(type.to_s, :default_icon) || 'fas fa-bullhorn'
  end

  def self.news_type_options
    NEWS_TYPES.map { |key, meta| [meta[:label], key] }
  end

  def self.icon_options
    ICONS.map { |icon| [icon[:label], icon[:value]] }
  end

  private

  def apply_default_icon
    return if icon.present?

    self.icon = self.class.default_icon_for(news_type)
  end

  def set_default_published_at
    self.published_at ||= Time.current
  end
end
