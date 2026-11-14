# frozen_string_literal: true

require 'test_helper'

class ExternalCatalogCandidateMatrixChoiceTest < ActiveSupport::TestCase
  setup do
    @user = register_for_test_cleanup(
      User.create!(email: "ecc_mc_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @other = register_for_test_cleanup(
      User.create!(email: "ecc_mc_o_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    external_id = "mc-#{SecureRandom.hex(4)}"
    @candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: external_id,
        provider_tag: 'CELLxGENE',
        title: "Matrix choice #{external_id}",
        url: "https://example.com/#{external_id}.h5ad",
        import_status: 'importing',
        import_user_id: @user.id,
        tax_id: 9606
      )
    )
    @fu = register_for_test_cleanup(
      Fu.create!(user_id: @user.id, upload_file_name: 'input_file.h5ad', upload_file_size: 0, status: 'preparsed')
    )
    @dir = @fu.upload_dir
    FileUtils.mkdir_p(@dir)
    File.write(@dir.join('input_file.h5ad'), 'h5ad bytes')
    File.write(
      @dir.join('output.json'),
      {
        'detected_format' => 'H5AD',
        'list_groups' => [
          { 'group' => '/X', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 0 },
          { 'group' => '/layers/raw_count_cellbender', 'nber_rows' => 3, 'nber_cols' => 4, 'is_count' => 1 }
        ]
      }.to_json
    )
  end

  teardown do
    FileUtils.rm_rf(@dir) if @dir
  end

  test 'a signed-in import waits for its own user' do
    @candidate.await_matrix_choice!(fu: @fu, version_id: 7, skip_archive: true)

    assert @candidate.awaiting_matrix?
    refute @candidate.can_create_project?(accessible_asap_projects: [])
    assert_equal @fu.id, @candidate.import_resume['fu_id']
    assert_equal 7, @candidate.import_resume['version_id']
    assert_equal %w[/X /layers/raw_count_cellbender], @candidate.pending_matrix_choices.map { |c| c['path'] }
    assert @candidate.matrix_choice_owner?(user: @user, sandbox_key: nil)
    refute @candidate.matrix_choice_owner?(user: @other, sandbox_key: nil)
    refute @candidate.matrix_choice_owner?(user: nil, sandbox_key: 'some-guest-session')
  end

  test 'a guest import waits for the same guest session and does not store its key' do
    @candidate.await_matrix_choice!(fu: @fu, version_id: 7, skip_archive: true, sandbox_key: 'guest-key-123')

    refute_includes @candidate.import_resume_json, 'guest-key-123'
    assert @candidate.matrix_choice_owner?(user: nil, sandbox_key: 'guest-key-123')
    refute @candidate.matrix_choice_owner?(user: nil, sandbox_key: 'another-key')
    refute @candidate.matrix_choice_owner?(user: @user, sandbox_key: nil)
  end

  test 'cancel deletes the download and frees the candidate' do
    @candidate.await_matrix_choice!(fu: @fu, version_id: 7, skip_archive: true)

    assert @candidate.cancel_matrix_choice!
    @candidate.reload
    assert_equal 'idle', @candidate.import_status
    assert_nil @candidate.import_resume_json
    assert_nil Fu.find_by(id: @fu.id)
    refute File.exist?(@dir)
  end

  test 'unanswered choices expire after MATRIX_CHOICE_TTL' do
    @candidate.await_matrix_choice!(fu: @fu, version_id: 7, skip_archive: true)
    refute @candidate.matrix_choice_expired?
    assert_equal 0, ExternalCatalogCandidate.where(id: @candidate.id).release_expired_matrix_choices!

    resume = @candidate.import_resume.merge(
      'awaiting_since' => (ExternalCatalogCandidate::MATRIX_CHOICE_TTL + 5.minutes).ago.iso8601
    )
    @candidate.update!(import_resume_json: resume.to_json)
    assert @candidate.matrix_choice_expired?
    assert @candidate.can_create_project?(accessible_asap_projects: [])

    assert_equal 1, ExternalCatalogCandidate.where(id: @candidate.id).release_expired_matrix_choices!
    assert_equal 'idle', @candidate.reload.import_status
    assert_nil Fu.find_by(id: @fu.id)
  end
end
