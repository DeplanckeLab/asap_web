# frozen_string_literal: true

# Builds Elasticsearch must-clauses for the project search box.
#
# Whitespace splits terms. Hyphens stay inside a term (sctg-seq). Quoted
# phrases stay together. * and ? are wildcards. Terms are ANDed. Fuzziness
# applies only to plain tokens of 6+ characters so short tokens such as seq
# cannot match RNA-seq via an edit.
class ProjectSearchQuery
  TEXT_FIELDS = [
    ['name', 3],
    ['key', 2],
    ['description', 1],
    ['owner_email', 2]
  ].freeze

  HYPHEN_FIELDS = [
    ['name.hyphen', 3],
    ['key.hyphen', 2],
    ['description.hyphen', 1]
  ].freeze

  KEYWORD_FIELDS = [
    ['technology', 1],
    ['owner_email.raw', 2]
  ].freeze

  MIN_FUZZY_LENGTH = 6

  def self.must_clauses(query)
    new(query).must_clauses
  end

  def self.tokens(query)
    new(query).tokens
  end

  def initialize(query)
    @query = query.to_s.strip
  end

  def must_clauses
    return email_clause if email_query?

    tokens.filter_map { |token| clause_for_token(token) }
  end

  def tokens
    return [] if @query.blank?

    parsed = []
    rest = @query
    until rest.empty?
      rest = rest.lstrip
      break if rest.empty?

      if rest.start_with?('"')
        match = rest.match(/\A"([^"]*)"?/)
        value = match[1].to_s.strip
        parsed << { type: :phrase, value: value } if value.present?
        rest = match.post_match
      else
        match = rest.match(/\A\S+/)
        parsed << classify_token(match[0])
        rest = match.post_match
      end
    end
    parsed
  end

  private

  def email_query?
    @query.include?('@') && !@query.match?(/\s/)
  end

  def email_clause
    [{ term: { 'owner_email.raw' => @query.downcase } }]
  end

  def classify_token(raw)
    if raw.include?('*') || raw.include?('?')
      { type: :wildcard, value: raw }
    elsif raw.include?('-')
      { type: :hyphenated, value: raw }
    else
      { type: :term, value: raw }
    end
  end

  def clause_for_token(token)
    should =
      case token[:type]
      when :wildcard
        wildcard_should(token[:value])
      when :phrase
        phrase_should(token[:value])
      when :hyphenated
        hyphenated_should(token[:value])
      else
        term_should(token[:value])
      end

    {
      bool: {
        should: should,
        minimum_should_match: 1
      }
    }
  end

  def wildcard_should(value)
    pattern = value.downcase
    (HYPHEN_FIELDS + KEYWORD_FIELDS).map do |field, boost|
      { wildcard: { field => { value: pattern, case_insensitive: true, boost: boost } } }
    end + TEXT_FIELDS.map do |field, boost|
      { wildcard: { field => { value: pattern, case_insensitive: true, boost: boost } } }
    end
  end

  def phrase_should(value)
    TEXT_FIELDS.map { |field, boost| { match_phrase: { field => { query: value, boost: boost } } } } +
      HYPHEN_FIELDS.map { |field, boost| { match_phrase: { field => { query: value, boost: boost } } } }
  end

  def hyphenated_should(value)
    hyphen_match = { query: value }
    # Fuzz the whole assay token (sctg-seq -> sctf-seq). Do not fuzzy the
    # english phrase, or seq would again match RNA-seq.
    hyphen_match[:fuzziness] = 1 if value.length >= MIN_FUZZY_LENGTH

    HYPHEN_FIELDS.map { |field, boost| { match: { field => hyphen_match.merge(boost: boost) } } } +
      TEXT_FIELDS.map { |field, boost| { match_phrase: { field => { query: value, boost: boost } } } } +
      KEYWORD_FIELDS.map { |field, boost| { term: { field => { value: value.downcase, boost: boost } } } }
  end

  def term_should(value)
    match_body = { query: value, operator: 'and' }
    match_body[:fuzziness] = 'AUTO' if value.length >= MIN_FUZZY_LENGTH

    TEXT_FIELDS.map { |field, boost| { match: { field => match_body.merge(boost: boost) } } } +
      HYPHEN_FIELDS.map { |field, boost| { match: { field => { query: value, boost: boost } } } } +
      KEYWORD_FIELDS.map { |field, boost| { term: { field => { value: value.downcase, boost: boost } } } }
  end
end
