# frozen_string_literal: true

class StandaloneComplianceChecksController < ApplicationController
  include ComplianceHelpers

  before_action :authenticate_user!
  before_action :authorize_admin
  before_action :set_standalone_compliance_check, only: :show

  def index
    @standalone_compliance_checks = StandaloneComplianceCheck.includes(:user).recent
    @total_count = StandaloneComplianceCheck.count
    @passed_count = StandaloneComplianceCheck.passed.count
    @failed_status_count = StandaloneComplianceCheck.where(status: 'failed').count
  end

  def show
    @validation_result = validation_result_from_check(@standalone_compliance_check)
    @compliance_check_groups = resolve_compliance_check_groups(@validation_result) if @validation_result.present?
  end

  private

  def set_standalone_compliance_check
    @standalone_compliance_check = StandaloneComplianceCheck.find(params[:id])
  end

  def validation_result_from_check(check)
    return nil if check.status == 'failed'
    return nil if check.result_json.blank?

    check.result_json.with_indifferent_access
  end
end
