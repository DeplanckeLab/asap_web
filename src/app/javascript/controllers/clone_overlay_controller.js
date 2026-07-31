import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.submitting = false
    this._onKeyDown = this._onKeyDown.bind(this)
  }

  disconnect() {
    this.removeConfirmModal()
  }

  handleClick(event) {
    event.preventDefault()

    if (this.submitting) {
      return
    }

    const form = this.element.closest("form")
    if (!form) {
      return
    }

    const skipConfirm = this.element.dataset.cloneOverlaySkipConfirm === "true"
    if (skipConfirm) {
      this.submitClone(form)
      return
    }

    const message = this.element.dataset.cloneOverlayConfirmValue || "Clone this project?"
    this.showConfirmModal(message, () => this.submitClone(form))
  }

  handleSubmit(event) {
    if (this.submitting) {
      this.showOverlay()
      return
    }

    event.preventDefault()
    const message = this.element.dataset.cloneOverlayConfirmValue || "Clone this project?"
    this.showConfirmModal(message, () => {
      this.submitting = true
      this.showOverlay()
      this.element.requestSubmit()
    })
  }

  submitClone(form) {
    this.submitting = true
    this.showOverlay()
    form.requestSubmit()
  }

  showConfirmModal(message, onConfirm) {
    this.removeConfirmModal()

    const overlay = document.createElement("div")
    overlay.id = "clone-confirm-modal"
    overlay.className = "fixed inset-0 z-50 flex items-center justify-center"
    overlay.setAttribute("role", "dialog")
    overlay.setAttribute("aria-modal", "true")
    overlay.setAttribute("aria-labelledby", "clone-confirm-modal-title")

    const backdrop = document.createElement("div")
    backdrop.className = "absolute inset-0 bg-black/40"

    const panel = document.createElement("div")
    panel.className = "relative bg-white rounded-lg shadow-xl max-w-md w-full mx-4 border border-gray-200"

    const header = document.createElement("div")
    header.className = "px-5 py-4 border-b border-gray-200"
    const title = document.createElement("h2")
    title.id = "clone-confirm-modal-title"
    title.className = "text-base font-semibold text-gray-900 m-0"
    title.textContent = "Confirm clone"
    header.appendChild(title)

    const body = document.createElement("div")
    body.className = "px-5 py-4"
    const messageEl = document.createElement("p")
    messageEl.className = "text-sm text-gray-700 m-0"
    messageEl.textContent = message
    body.appendChild(messageEl)

    const footer = document.createElement("div")
    footer.className = "px-5 py-4 border-t border-gray-200 flex justify-end gap-2"

    const cancelButton = document.createElement("button")
    cancelButton.type = "button"
    cancelButton.className = "inline-flex items-center px-4 py-2 rounded-md border border-gray-200 text-sm text-gray-700 hover:bg-gray-50"
    cancelButton.textContent = "Cancel"

    const confirmButton = document.createElement("button")
    confirmButton.type = "button"
    confirmButton.className = "inline-flex items-center px-4 py-2 rounded-md bg-emerald-600 text-white text-sm font-medium hover:bg-emerald-700"
    confirmButton.textContent = "Clone"

    footer.appendChild(cancelButton)
    footer.appendChild(confirmButton)

    panel.appendChild(header)
    panel.appendChild(body)
    panel.appendChild(footer)
    overlay.appendChild(backdrop)
    overlay.appendChild(panel)
    document.body.appendChild(overlay)
    document.body.classList.add("overflow-hidden")

    const close = () => this.removeConfirmModal()

    cancelButton.addEventListener("click", close)
    backdrop.addEventListener("click", close)
    panel.addEventListener("click", (event) => event.stopPropagation())
    confirmButton.addEventListener("click", () => {
      close()
      onConfirm()
    })

    document.addEventListener("keydown", this._onKeyDown)
    confirmButton.focus()
  }

  _onKeyDown(event) {
    if (event.key === "Escape") {
      this.removeConfirmModal()
    }
  }

  removeConfirmModal() {
    const existing = document.getElementById("clone-confirm-modal")
    if (existing) existing.remove()
    document.body.classList.remove("overflow-hidden")
    document.removeEventListener("keydown", this._onKeyDown)
  }

  showOverlay() {
    const existing = document.getElementById('clone-loading-overlay')
    if (existing) existing.remove()

    const overlay = document.createElement('div')
    overlay.id = 'clone-loading-overlay'
    overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background-color:rgba(0,0,0,0.5);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;'
    overlay.innerHTML = `
      <div style="background:white;border-radius:12px;padding:32px 48px;text-align:center;max-width:480px;">
        <svg style="width:48px;height:48px;margin:0 auto 16px;color:#3b82f6;" viewBox="0 0 24 24" fill="none">
          <circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="2" opacity="0.2"/>
          <path d="M12 2a10 10 0 0 1 10 10" stroke="currentColor" stroke-width="2" stroke-linecap="round">
            <animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="1s" repeatCount="indefinite"/>
          </path>
        </svg>
        <p style="font-size:16px;font-weight:500;color:#1f2937;margin:0;">Cloning project...</p>
        <p style="font-size:13px;color:#6b7280;margin-top:8px;">Please wait, this may take a moment.</p>
      </div>
    `
    document.body.appendChild(overlay)
  }
}
