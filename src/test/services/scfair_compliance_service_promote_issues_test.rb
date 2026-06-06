# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class ScfairComplianceServicePromoteIssuesTest < TestBaseWithoutFixtures
  test 'promote_valid_check_issues copies warning status checks into warnings' do
    service = ScfairComplianceService.allocate
    valid_checks = [
      { field: 'extension.atac', status: 'warning', message: 'ATAC extension detected' },
      { field: 'extension.analysis_json', status: 'warning', message: 'analysis_json metadata not found (recommended)' },
      { field: 'obs/title', status: 'passed', message: 'Required field present' }
    ]

    errors, warnings = service.send(
      :promote_valid_check_issues,
      valid_checks,
      [],
      [{ field: 'extension.atac', message: 'Already listed' }]
    )

    assert_empty errors
    assert_equal 2, warnings.size
    assert warnings.any? { |entry| entry[:field] == 'extension.atac' && entry[:message] == 'Already listed' }
    assert warnings.any? { |entry| entry[:field] == 'extension.analysis_json' }
  end
end
