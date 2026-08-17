# frozen_string_literal: true

# Identifies search-engine crawlers that index the public site for SEO.
# These agents may read the public UI but must never trigger project unarchive.
class SearchEngineCrawler
  USER_AGENT_PATTERNS = [
    /Googlebot/i,
    /Google-InspectionTool/i,
    /GoogleOther/i,
    /Storebot-Google/i,
    /AdsBot-Google/i,
    /APIs-Google/i,
    /bingbot/i,
    /BingPreview/i,
    /adidxbot/i,
    /msnbot/i,
    /DuckDuckBot/i,
    /Slurp/i,
    /yandexbot/i,
    /yandeximages/i,
    /Baiduspider/i,
    /Applebot/i,
    /Sogou/i,
    /Naverbot/i,
    /\bYeti\b/i,
    /SeznamBot/i,
    /MojeekBot/i,
    /Qwantify/i,
    /PetalBot/i,
    /Amazonbot/i,
    /OAI-SearchBot/i,
    /PerplexityBot/i,
    /YouBot/i
  ].freeze

  def self.match?(user_agent)
    ua = user_agent.to_s
    return false if ua.blank?

    USER_AGENT_PATTERNS.any? { |pattern| pattern.match?(ua) }
  end
end
