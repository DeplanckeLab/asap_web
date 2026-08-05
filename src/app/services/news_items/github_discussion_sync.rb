# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

# One-way ASAP news -> GitHub Discussions sync (create or update).
#
# Each news type is posted under its own Discussions category (thread section).
#
# Required ENV:
#   GITHUB_DISCUSSIONS_TOKEN  - PAT or GitHub App token with discussions:write
#
# Optional ENV:
#   GITHUB_DISCUSSIONS_REPO   - "owner/name" (default: DeplanckeLab/asap_web)
#   GITHUB_DISCUSSIONS_CATEGORY_RELEASE
#   GITHUB_DISCUSSIONS_CATEGORY_FEATURE
#   GITHUB_DISCUSSIONS_CATEGORY_ANNOUNCEMENT
#   GITHUB_DISCUSSIONS_CATEGORY_TIP
#   GITHUB_DISCUSSIONS_CATEGORY - fallback category name if a type-specific one is unset
class NewsItems::GithubDiscussionSync
  class Error < StandardError; end

  GRAPHQL_URL = 'https://api.github.com/graphql'
  SYNCABLE_TYPES = %w[release feature announcement tip].freeze

  DEFAULT_CATEGORY_BY_TYPE = {
    'release' => 'New releases',
    'feature' => 'Features / Updates',
    'announcement' => 'Technical announcements',
    'tip' => 'Tips'
  }.freeze

  Result = Struct.new(:created, :discussion_url, :discussion_number, :node_id, :category_name, keyword_init: true)

  def initialize(news_item, logger: Rails.logger)
    @news_item = news_item
    @logger = logger
  end

  def call
    validate_syncable!
    validate_config!

    title = discussion_title
    body = discussion_body
    repo = repository_metadata!
    category_name = self.class.category_name_for(@news_item.news_type)
    category_id = category_id_for!(repo.fetch(:categories), category_name)

    if @news_item.github_discussion_node_id.present?
      payload = update_discussion!(
        discussion_id: @news_item.github_discussion_node_id,
        category_id: category_id,
        title: title,
        body: body
      )
      created = false
    else
      payload = create_discussion!(
        repository_id: repo.fetch(:id),
        category_id: category_id,
        title: title,
        body: body
      )
      created = true
    end

    discussion = payload.fetch('discussion')
    node_id = discussion.fetch('id')
    number = discussion.fetch('number')
    url = discussion.fetch('url')

    @news_item.update!(
      github_discussion_node_id: node_id,
      github_discussion_number: number,
      github_discussion_url: url,
      github_synced_at: Time.current
    )

    Result.new(
      created: created,
      discussion_url: url,
      discussion_number: number,
      node_id: node_id,
      category_name: category_name
    )
  end

  def self.syncable?(news_item)
    SYNCABLE_TYPES.include?(news_item.news_type.to_s)
  end

  def self.configured?
    token.present?
  end

  def self.token
    Rails.application.credentials.dig(:github, :discussions_token).to_s.presence ||
      ENV['GITHUB_DISCUSSIONS_TOKEN'].to_s.presence ||
      ENV['GITHUB_TOKEN'].to_s.presence
  end

  def self.repo_slug
    ENV.fetch('GITHUB_DISCUSSIONS_REPO', 'DeplanckeLab/asap_web').to_s.strip
  end

  def self.category_name_for(news_type)
    type = news_type.to_s
    env_key = "GITHUB_DISCUSSIONS_CATEGORY_#{type.upcase}"
    ENV[env_key].to_s.strip.presence ||
      ENV['GITHUB_DISCUSSIONS_CATEGORY'].to_s.strip.presence ||
      DEFAULT_CATEGORY_BY_TYPE.fetch(type) do
        raise Error, "No GitHub Discussions category mapping for news type #{type.inspect}."
      end
  end

  private

  def validate_syncable!
    return if self.class.syncable?(@news_item)

    raise Error, "News type '#{@news_item.news_type}' is not synced to GitHub Discussions (alerts stay on ASAP only)."
  end

  def validate_config!
    raise Error, 'GitHub Discussions sync is not configured (missing GITHUB_DISCUSSIONS_TOKEN).' unless self.class.configured?

    owner, name = self.class.repo_slug.split('/', 2)
    raise Error, "Invalid GITHUB_DISCUSSIONS_REPO=#{self.class.repo_slug.inspect} (expected owner/name)." if owner.blank? || name.blank?
  end

  def discussion_title
    plain_text(@news_item.title).presence || raise(Error, 'News title is blank after removing HTML.')
  end

  def discussion_body
    plain = plain_text(@news_item.body)
    type_line = "**#{@news_item.type_label}** · published #{@news_item.published_at.strftime('%Y-%m-%d')}"
    asap_url = news_item_public_url

    [
      type_line,
      '',
      plain,
      '',
      '---',
      "_Also published on [ASAP news](#{asap_url})._"
    ].join("\n")
  end

  def plain_text(value)
    html = value.to_s
      .gsub(/\r\n?/, "\n")
      .gsub(%r{<br\s*/?>}i, "\n")
      .gsub(%r{</p>}i, "\n\n")
      .gsub(%r{</div>}i, "\n")
      .gsub(%r{</li>}i, "\n")
      .gsub(%r{<li[^>]*>}i, '- ')

    ActionController::Base.helpers.strip_tags(html).gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
  end

  def news_item_public_url
    base = ENV['SERVER_URL'].to_s.chomp('/')
    path = "/news_items#news-item-#{@news_item.id}"
    base.present? ? "#{base}#{path}" : path
  end

  def repository_metadata!
    owner, name = self.class.repo_slug.split('/', 2)
    query = <<~GRAPHQL
      query($owner: String!, $name: String!) {
        repository(owner: $owner, name: $name) {
          id
          discussionCategories(first: 50) {
            nodes { id name }
          }
        }
      }
    GRAPHQL

    data = graphql!(query, { owner: owner, name: name })
    repo = data.dig('repository')
    raise Error, "GitHub repository #{self.class.repo_slug.inspect} was not found." if repo.blank?

    {
      id: repo.fetch('id'),
      categories: Array(repo.dig('discussionCategories', 'nodes'))
    }
  end

  def category_id_for!(categories, wanted)
    match = categories.find { |c| c['name'].to_s.casecmp?(wanted) }
    return match.fetch('id') if match

    available = categories.map { |c| c['name'] }.compact.join(', ')
    raise Error, "Discussion category #{wanted.inspect} not found in #{self.class.repo_slug}. Available: #{available}"
  end

  def create_discussion!(repository_id:, category_id:, title:, body:)
    mutation = <<~GRAPHQL
      mutation($repositoryId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
        createDiscussion(input: {
          repositoryId: $repositoryId,
          categoryId: $categoryId,
          title: $title,
          body: $body
        }) {
          discussion {
            id
            number
            url
          }
        }
      }
    GRAPHQL

    graphql!(
      mutation,
      {
        repositoryId: repository_id,
        categoryId: category_id,
        title: title,
        body: body
      }
    ).fetch('createDiscussion')
  end

  def update_discussion!(discussion_id:, category_id:, title:, body:)
    mutation = <<~GRAPHQL
      mutation($discussionId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
        updateDiscussion(input: {
          discussionId: $discussionId,
          categoryId: $categoryId,
          title: $title,
          body: $body
        }) {
          discussion {
            id
            number
            url
          }
        }
      }
    GRAPHQL

    graphql!(
      mutation,
      {
        discussionId: discussion_id,
        categoryId: category_id,
        title: title,
        body: body
      }
    ).fetch('updateDiscussion')
  end

  def graphql!(query, variables)
    uri = URI.parse(GRAPHQL_URL)
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{self.class.token}"
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request['User-Agent'] = 'ASAP-NewsSync'
    request.body = { query: query, variables: variables }.to_json

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      @logger.error("[NewsItems::GithubDiscussionSync] HTTP #{response.code}: #{response.body}")
      raise Error, "GitHub API HTTP #{response.code}"
    end

    parsed = JSON.parse(response.body)
    if parsed['errors'].present?
      messages = Array(parsed['errors']).map { |e| e['message'] }.join('; ')
      @logger.error("[NewsItems::GithubDiscussionSync] GraphQL errors: #{messages}")
      raise Error, "GitHub GraphQL error: #{messages}"
    end

    parsed.fetch('data')
  rescue JSON::ParserError => e
    raise Error, "Invalid GitHub API response: #{e.message}"
  end
end
