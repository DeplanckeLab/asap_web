import { Controller } from "@hotwired/stimulus"
import { ensurePipelineRunsCard, hidePipelineRunsPanel, showPipelineRunsPanel } from "controllers/pipeline_runs_panel"

export default class extends Controller {
  static values = {
    annotId: Number,
    runId: Number,
    projectId: Number,
    url: String
  }

  connect() {
    ensurePipelineRunsCard()
  }

  showPipeline(event) {
    event.preventDefault()
    event.stopPropagation()

    showPipelineRunsPanel({
      url: this.urlValue,
      annotId: this.hasAnnotIdValue ? this.annotIdValue : null,
      runId: this.hasRunIdValue ? this.runIdValue : null,
      anchorElement: event.currentTarget
    })
  }

  hidePipeline(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    hidePipelineRunsPanel()
  }
}
