import { Controller } from "@hotwired/stimulus"
import { complianceCheckReportMixin } from "controllers/concerns/compliance_check_report_mixin"

class ComplianceCheckReportController extends Controller {
  static targets = [
    "resultBody",
    "detailModal",
    "detailDialog",
    "detailSplit",
    "detailTitle",
    "detailStatusBadge",
    "detailBody",
    "detailYamlPanel",
    "detailYamlContent",
    "detailYamlHighlight"
  ]

  static values = {
    result: Object,
    rulesSnippetUrl: String,
    rulesYamlUrl: String,
    showResultBanner: { type: Boolean, default: false },
    schemaId: String
  }

  connect() {
    this.initComplianceCheckReportState()
    if (this.hasResultValue) {
      this.renderResult(this.resultValue, {
        showResultBanner: this.showResultBannerValue,
        revealResultWrap: false
      })
    }
  }
}

Object.assign(ComplianceCheckReportController.prototype, complianceCheckReportMixin)

export default ComplianceCheckReportController
