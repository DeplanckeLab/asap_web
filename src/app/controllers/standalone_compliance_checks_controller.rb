# frozen_string_literal: true

class StandaloneComplianceChecksController < ApplicationController
  include ComplianceHelpers

  before_action :authenticate_user!
  before_action :authorize_admin
  before_action :set_standalone_compliance_check, only: :show

  def index
    @origin_filter = StandaloneComplianceCheck.origin_filter(params[:origin])
    scope = StandaloneComplianceCheck.for_origin_filter(@origin_filter).includes(:user).recent
    @standalone_compliance_checks = scope
    @total_count = scope.count
    @passed_count = scope.passed.count
    @failed_status_count = scope.where(status: 'failed').count
    @all_count = StandaloneComplianceCheck.count
    @admin_count = StandaloneComplianceCheck.admin_runs.count
    @user_count = StandaloneComplianceCheck.user_runs.count
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
