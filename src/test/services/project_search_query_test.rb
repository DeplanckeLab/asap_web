# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ProjectSearchQueryTest < TestBaseWithoutFixtures
  test 'splits on whitespace and keeps hyphenated assay names together' do
    tokens = ProjectSearchQuery.tokens('sctg-seq atlas')

    assert_equal(
      [
        { type: :hyphenated, value: 'sctg-seq' },
        { type: :term, value: 'atlas' }
      ],
      tokens
    )
  end

  test 'treats quoted text as a single phrase' do
    tokens = ProjectSearchQuery.tokens('"human cell atlas" sctg-seq')

    assert_equal(
      [
        { type: :phrase, value: 'human cell atlas' },
        { type: :hyphenated, value: 'sctg-seq' }
      ],
      tokens
    )
  end

  test 'classifies glob characters as wildcard tokens' do
    tokens = ProjectSearchQuery.tokens('sctg-seq atlas*')

    assert_equal(
      [
        { type: :hyphenated, value: 'sctg-seq' },
        { type: :wildcard, value: 'atlas*' }
      ],
      tokens
    )
  end

  test 'ANDs every token so seq alone cannot satisfy sctg-seq atlas' do
    clauses = ProjectSearchQuery.must_clauses('sctg-seq atlas')

    assert_equal 2, clauses.size
    assert_equal 1, clauses.dig(0, :bool, :minimum_should_match)
    assert_equal 1, clauses.dig(1, :bool, :minimum_should_match)
  end

  test 'hyphenated assay is a phrase on english fields and a unit on hyphen fields' do
    hyphen_clause = ProjectSearchQuery.must_clauses('sctg-seq atlas').first
    should = hyphen_clause.dig(:bool, :should)

    assert should.any? { |q| q.dig(:match_phrase, 'name', :query) == 'sctg-seq' }
    assert should.any? { |q| q.dig(:match, 'name.hyphen', :query) == 'sctg-seq' }
    assert should.any? { |q| q.dig(:term, 'technology', :value) == 'sctg-seq' }
    hyphen_match = should.find { |q| q.dig(:match, 'name.hyphen') }
    assert_equal 1, hyphen_match.dig(:match, 'name.hyphen', :fuzziness)
    phrase_queries = should.select { |q| q[:match_phrase] }
    assert phrase_queries.any?
    assert_not phrase_queries.any? { |q| q[:match_phrase].values.any? { |body| body[:fuzziness] } }
  end

  test 'does not use fuzziness on short tokens such as atlas' do
    atlas_clause = ProjectSearchQuery.must_clauses('sctg-seq atlas').last
    should = atlas_clause.dig(:bool, :should)
    match_queries = should.select { |q| q[:match] }

    assert match_queries.any? { |q| q.dig(:match, 'name', :query) == 'atlas' }
    assert_not match_queries.any? { |q| q[:match].values.any? { |body| body[:fuzziness] } }
  end

  test 'uses AUTO fuzziness only for plain tokens of 6 or more characters' do
    should = ProjectSearchQuery.must_clauses('haltere').first.dig(:bool, :should)
    name_match = should.find { |q| q.dig(:match, 'name') }

    assert_equal 'AUTO', name_match.dig(:match, 'name', :fuzziness)
  end

  test 'looks up a bare email on the raw owner email field' do
    clauses = ProjectSearchQuery.must_clauses('Owner@Example.com')

    assert_equal [{ term: { 'owner_email.raw' => 'owner@example.com' } }], clauses
  end
end
