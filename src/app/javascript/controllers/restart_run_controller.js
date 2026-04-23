import { Controller } from "@hotwired/stimulus"

// Restart a single run without going through the form.
// Used for steps with multiple_runs == true (e.g. DE, GE, clustering),
// where the Reset button is not applicable.
export default class extends Controller {
  static values = {
    runId: Number,
    stepId: Number,
    restartUrl: String,
    runsListUrl: String
  }

  connect() {}

  showLoadingOverlay(message) {
    const existingOverlay = document.getElementById('restart-run-loading-overlay')
    if (existingOverlay) existingOverlay.remove()

    const overlay = document.createElement('div')
    overlay.id = 'restart-run-loading-overlay'
    overlay.style.cssText = `
      position: fixed;
      top: 0; left: 0; right: 0; bottom: 0;
      background-color: rgba(0, 0, 0, 0.5);
      z-index: 9999;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-start;
      padding-top: 100px;
    `

    const messageContainer = document.createElement('div')
    messageContainer.style.cssText = `
      background-color: white;
      padding: 24px 32px;
      border-radius: 8px;
      box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 16px;
    `

    const spinner = document.createElement('div')
    spinner.innerHTML = `
      <svg class="animate-spin" style="width: 32px; height: 32px; color: #2563eb;" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
      </svg>
    `

    const messageEl = document.createElement('div')
    messageEl.textContent = message || 'Restarting run...'
    messageEl.style.cssText = `
      font-size: 18px;
      font-weight: 500;
      color: #374151;
    `

    messageContainer.appendChild(spinner)
    messageContainer.appendChild(messageEl)
    overlay.appendChild(messageContainer)

    if (!document.getElementById('restart-run-spinner-styles')) {
      const style = document.createElement('style')
      style.id = 'restart-run-spinner-styles'
      style.textContent = `
        @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
        .animate-spin { animation: spin 1s linear infinite; }
      `
      document.head.appendChild(style)
    }

    document.body.style.pointerEvents = 'none'
    document.body.style.userSelect = 'none'
    document.body.appendChild(overlay)
  }

  hideLoadingOverlay() {
    const overlay = document.getElementById('restart-run-loading-overlay')
    if (overlay) overlay.remove()
    document.body.style.pointerEvents = ''
    document.body.style.userSelect = ''
  }

  restart(event) {
    event.preventDefault()
    event.stopPropagation()

    if (!this.hasRestartUrlValue || !this.hasRunIdValue) {
      console.error('[RestartRunController] Missing required values')
      return
    }

    if (!confirm('Restart this run with the same parameters? Existing output files for this run will be overwritten.')) {
      return
    }

    this.showLoadingOverlay('Restarting run...')
    this.element.disabled = true
    this.element.style.opacity = '0.6'
    this.element.style.cursor = 'not-allowed'

    const csrfToken = document.querySelector('meta[name="csrf-token"]')
    const headers = { 'Accept': 'application/json' }
    if (csrfToken) {
      headers['X-CSRF-Token'] = csrfToken.getAttribute('content')
    }

    fetch(this.restartUrlValue, { method: 'POST', headers: headers, credentials: 'same-origin' })
      .then((response) => response.json().then((body) => ({ ok: response.ok, body: body })))
      .then(({ ok, body }) => {
        this.hideLoadingOverlay()
        this.element.disabled = false
        this.element.style.opacity = ''
        this.element.style.cursor = ''

        if (!ok || !body || body.status !== 'ok') {
          const message = (body && body.message) ? body.message : 'Could not restart this run.'
          alert(message)
          return
        }

        if (this.hasRunsListUrlValue && typeof loadFormInRightPanel === 'function') {
          loadFormInRightPanel(this.runsListUrlValue)
        } else if (typeof loadRunInRightPanel === 'function') {
          loadRunInRightPanel(`/runs/${body.run_id}`, String(body.step_id))
        } else {
          window.location.reload()
        }
      })
      .catch((err) => {
        this.hideLoadingOverlay()
        this.element.disabled = false
        this.element.style.opacity = ''
        this.element.style.cursor = ''
        console.error('[RestartRunController] Error restarting run:', err)
        alert('Could not restart this run: ' + err.message)
      })
  }
}
