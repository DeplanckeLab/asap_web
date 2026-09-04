# frozen_string_literal: true

require_relative '../services/test_base_without_fixtures'

class StandaloneComplianceCheckPortalFilterTest < TestBaseWithoutFixtures
  test 'for_portal_source limits checks to matching catalog candidate URLs' do
    ebi_url = "https://example.com/ebi-#{SecureRandom.hex(4)}.h5ad"
    cxg_url = "https://example.com/cxg-#{SecureRandom.hex(4)}.h5ad"

    register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'ebi_sc',
        external_id: "portal-ebi-#{SecureRandom.hex(4)}",
        provider_tag: 'EBI_SC',
        title: 'EBI portal filter',
        url: ebi_url,
        filename: 'ebi.h5ad',
        format_kind: 'h5ad',
        project_type_tag: 'sc',
        filesize: 10,
        obsolete: false
      )
    )
    register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "portal-cxg-#{SecureRandom.hex(4)}",
        provider_tag: 'CELLxGENE',
        title: 'CXG portal filter',
        url: cxg_url,
        filename: 'cxg.h5ad',
        format_kind: 'h5ad',
        project_type_tag: 'sc',
        filesize: 10,
        obsolete: false
      )
    )

    ebi_check = register_for_test_cleanup(
      StandaloneComplianceCheck.create!(
        task_id: SecureRandom.uuid,
        filename: 'ebi.h5ad',
        source_url: ebi_url,
        format: 'h5ad',
        schema_id: 'scfair_7_1_0',
        passed: true,
        status: 'completed',
        checked_at: Time.current,
        result_json: { 'valid' => true },
        admin_run: true
      )
    )
    cxg_check = register_for_test_cleanup(
      StandaloneComplianceCheck.create!(
        task_id: SecureRandom.uuid,
        filename: 'cxg.h5ad',
        source_url: cxg_url,
        format: 'h5ad',
        schema_id: 'scfair_7_1_0',
        passed: false,
        status: 'completed',
        checked_at: Time.current,
        result_json: { 'valid' => false },
        admin_run: true
      )
    )
    upload_check = register_for_test_cleanup(
      StandaloneComplianceCheck.create!(
        task_id: SecureRandom.uuid,
        filename: 'upload.h5ad',
        source_url: nil,
        format: 'h5ad',
        schema_id: 'scfair_7_1_0',
        passed: true,
        status: 'completed',
        checked_at: Time.current,
        result_json: { 'valid' => true },
        admin_run: false
      )
    )

    ebi_ids = StandaloneComplianceCheck.for_portal_source('ebi_sc').where(id: [ebi_check.id, cxg_check.id, upload_check.id]).pluck(:id)
    assert_equal [ebi_check.id], ebi_ids

    combined = StandaloneComplianceCheck
               .for_origin_filter('admin')
               .for_portal_source('ebi_sc')
               .where(id: [ebi_check.id, cxg_check.id, upload_check.id])
               .pluck(:id)
    assert_equal [ebi_check.id], combined

    assert_nil StandaloneComplianceCheck.portal_source_filter('')
    assert_nil StandaloneComplianceCheck.portal_source_filter('not_a_portal')
    assert_equal 'ebi_sc', StandaloneComplianceCheck.portal_source_filter('ebi_sc')

    all_ids = StandaloneComplianceCheck.for_portal_source(nil).where(id: [ebi_check.id, cxg_check.id, upload_check.id]).pluck(:id)
    assert_equal [ebi_check.id, cxg_check.id, upload_check.id].sort, all_ids.sort
  end
end
