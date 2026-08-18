# frozen_string_literal: true

require 'test_helper'

class AnnotsControllerTest < ActionDispatch::IntegrationTest
  CLAUDE_BOT_UA = 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0; +claudebot@anthropic.com)'
  AMAZON_SEARCH_BOT_UA = 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Amzn-SearchBot/0.1) Chrome/119.0.6045.214 Safari/537.36'

  setup do
    @user = register_for_test_cleanup(
      User.create!(email: "annot_dl_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @project = create_test_project!(
      name: 'Annot download policy',
      key: "adl#{SecureRandom.hex(3)}",
      user_id: @user.id,
      public: true
    )
    @matrix = register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        filepath: 'parsing/output.loom',
        name: '/matrix',
        dim: 3,
        nber_rows: 1000,
        nber_cols: 500,
        latest_version: true,
        version_nber: 1
      )
    )
    @metadata = register_for_test_cleanup(
      Annot.create!(
        project_id: @project.id,
        user_id: @user.id,
        filepath: 'parsing/output.loom',
        name: '/col_attrs/CellID',
        dim: 1,
        nber_cols: 500,
        latest_version: true,
        version_nber: 1
      )
    )
  end

  test 'robots cannot download annots' do
    get download_annot_path(@metadata, format_type: 'json'),
        headers: { 'User-Agent' => CLAUDE_BOT_UA }

    assert_response :forbidden
  end

  test 'amazon search bot cannot download annots' do
    get download_annot_path(@metadata, format_type: 'tsv.gz'),
        headers: { 'User-Agent' => AMAZON_SEARCH_BOT_UA }

    assert_response :forbidden
  end

  test 'expression matrix download is forbidden for users' do
    get download_annot_path(@matrix, format_type: 'json'),
        headers: { 'User-Agent' => 'Mozilla/5.0 Firefox/153.0' }

    assert_response :forbidden
    assert_match(/cannot be downloaded as TSV or JSON/, response.body)
  end
end
