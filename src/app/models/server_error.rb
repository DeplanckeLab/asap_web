# frozen_string_literal: true

class ServerError < ApplicationRecord
  belongs_to :user, optional: true

  validates :exception_class, presence: true
  validates :path, presence: true
  validates :http_method, presence: true
  validates :status, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def short_message(limit = 120)
    text = message.to_s.strip
    return '—' if text.blank?

    text.length > limit ? "#{text[0, limit]}..." : text
  end

  def backtrace_lines
    backtrace.to_s.lines.map(&:chomp).reject(&:blank?)
  end
end
