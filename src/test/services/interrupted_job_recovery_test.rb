# frozen_string_literal: true

require 'test_helper'

class InterruptedJobRecoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test 'worker_process is true for bin/jobs' do
    original = $PROGRAM_NAME
    $PROGRAM_NAME = '/app/bin/jobs'
    assert InterruptedJobRecovery.worker_process?
  ensure
    $PROGRAM_NAME = original
  end

  test 'worker_process is false for puma' do
    original = $PROGRAM_NAME
    $PROGRAM_NAME = 'puma'
    refute InterruptedJobRecovery.worker_process?
  ensure
    $PROGRAM_NAME = original
  end

  test 're-enqueues unarchive and archive jobs from status flags' do
    user = register_for_test_cleanup(
      User.create!(email: "recov_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    unarchiving = create_test_project!(
      user_id: user.id,
      input_filename: 'input_file.loom',
      archive_status_id: 4
    )
    archiving = create_test_project!(
      user_id: user.id,
      input_filename: 'input_file.loom',
      archive_status_id: 2
    )

    assert_enqueued_with(job: ProjectUnarchiveJob, args: [unarchiving.id]) do
      assert_enqueued_with(job: ArchiveProjectJob, args: [archiving.id]) do
        InterruptedJobRecovery.call
      end
    end
  end

  test 're-enqueues publication continue for being_published projects' do
    user = register_for_test_cleanup(
      User.create!(email: "recovp_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom', public: false)
    project.start_publishing!

    assert_enqueued_with(job: FinalizeProjectPublicationJob, args: [project.id]) do
      InterruptedJobRecovery.call
    end
  end

  test 're-enqueues fu download and preparsing from fu status' do
    user = register_for_test_cleanup(
      User.create!(email: "recovfu_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    version = Version.order(id: :desc).first
    skip 'no Version row' if version.nil?

    downloading = register_for_test_cleanup(
      Fu.create!(
        name: 'remote.h5ad',
        upload_file_name: 'input.h5ad',
        upload_file_size: 0,
        status: 'downloading',
        url: 'https://example.com/remote.h5ad',
        user_id: user.id,
        preparsing_version_id: version.id
      )
    )
    preparsing = register_for_test_cleanup(
      Fu.create!(
        name: 'local.h5ad',
        upload_file_name: 'input.h5ad',
        upload_file_size: 10,
        status: 'preparsing',
        user_id: user.id,
        preparsing_version_id: version.id
      )
    )

    assert_enqueued_with(job: FuDownloadFromUrlJob) do
      assert_enqueued_with(job: FuPreparsingJob) do
        InterruptedJobRecovery.call
      end
    end

    assert downloading.reload.status == 'downloading'
    assert preparsing.reload.status == 'preparsing'
  end

  test 'does not re-enqueue catalog import from importing status' do
    user = register_for_test_cleanup(
      User.create!(email: "recovcat_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'geo',
        external_id: "GSE#{SecureRandom.hex(4)}",
        provider_tag: 'geo',
        title: 'recovery candidate',
        url: 'https://example.com/file.h5ad',
        import_status: 'importing',
        import_user_id: user.id
      )
    )

    InterruptedJobRecovery.call

    assert_equal 'importing', candidate.reload.import_status
    if defined?(SolidQueue::Job) && SolidQueue::Job.table_exists?
      leaked = SolidQueue::Job.where(
        class_name: 'ExternalCatalogImportCandidateJob',
        finished_at: nil
      ).any? do |job|
        args = job.arguments
        first = args.is_a?(Hash) ? (args['arguments'] || args[:arguments] || []).first : nil
        first.to_i == candidate.id
      end
      refute leaked
    end
  end

  test 're-enqueues compliance url download from fu downloading status' do
    upload_type_id = UploadType.id_for('compliance_file_check')
    skip 'compliance_file_check upload type missing' if upload_type_id.blank?

    fu = register_for_test_cleanup(
      Fu.create!(
        name: 'remote.h5ad',
        upload_file_name: 'pending.download',
        upload_file_size: 0,
        status: 'downloading',
        url: 'https://example.com/remote.h5ad',
        upload_type: upload_type_id,
        compliance_schema_id: 'scfair_7_1_0',
        compliance_task_id: SecureRandom.uuid
      )
    )

    assert_enqueued_with(job: IsolatedComplianceUrlDownloadJob, args: [fu.id]) do
      InterruptedJobRecovery.call
    end
  end

  test 're-enqueues clone, validation, and module score from durable flags' do
    user = register_for_test_cleanup(
      User.create!(email: "recovmore_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    source = create_test_project!(user_id: user.id, input_filename: 'input_file.loom')
    dest = create_test_project!(
      user_id: user.id,
      input_filename: 'input_file.loom',
      cloned_project_id: source.id,
      being_cloned: true
    )
    validating = create_test_project!(user_id: user.id, input_filename: 'input_file.loom', being_validated: true)
    request = register_for_test_cleanup(
      ModuleScoreRequest.create!(
        request_id: SecureRandom.uuid,
        project_id: source.id,
        user_id: user.id,
        item_id: '123',
        loom_file: 'parsing/output.loom',
        dataset: '/matrix',
        status: 'running'
      )
    )

    assert_enqueued_with(job: ProjectCloneJob, args: [dest.id]) do
      assert_enqueued_with(job: ScfairValidationJob, args: [validating.id]) do
        assert_enqueued_with(job: GeneSetItemModuleScoreJob, args: [request.id]) do
          InterruptedJobRecovery.call
        end
      end
    end
  end

  test 're-enqueues gene set import from staged path and import_id' do
    type = GeneSetCollectionType.find_by(key: 'imported')
    skip 'imported gene set collection type missing' if type.nil?

    user = register_for_test_cleanup(
      User.create!(email: "recovgs_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    project = create_test_project!(user_id: user.id, input_filename: 'input_file.loom')
    import_id = SecureRandom.uuid
    staged_dir = GeneSetCollection.imports_dir
    FileUtils.mkdir_p(staged_dir)
    staged_path = staged_dir.join("#{project.id}_#{import_id}.gmt").to_s
    File.write(staged_path, "SETA\thttp://example.com\tGENE1\n")

    collection = register_for_test_cleanup(
      GeneSetCollection.create!(
        project_id: project.id,
        user_id: user.id,
        name: 'Imported sets',
        file_key: "gene_set_collection_#{SecureRandom.hex(6)}",
        source_kind: 'gmt',
        gene_set_collection_type_id: type.id,
        import_loom_file: 'parsing/output.loom',
        import_id: import_id
      )
    )

    begin
      assert_enqueued_with(job: GeneSetCollectionImportJob) do
        InterruptedJobRecovery.call
      end
    ensure
      FileUtils.rm_f(staged_path)
    end

    assert collection.reload.import_id == import_id
  end
end
