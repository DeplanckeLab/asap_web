import { Controller } from "@hotwired/stimulus"

const LINK_SELECTOR = "[data-reset-parsing-link]"

export default class extends Controller {
  visit(event) {
    if (document.body.dataset.resetParsingLocked === "true") {
      event.preventDefault()
      event.stopImmediatePropagation()
      return
    }

    document.body.dataset.resetParsingLocked = "true"
    this.lockAllLinks()
    this.showLoadingOverlay()
  }

  lockAllLinks() {
    document.querySelectorAll(LINK_SELECTOR).forEach((link) => {
      link.classList.add("opacity-60", "cursor-not-allowed", "pointer-events-none")
      link.setAttribute("aria-disabled", "true")
      link.tabIndex = -1
    })
  }

  showLoadingOverlay() {
    const existingOverlay = document.getElementById("reset-parsing-loading-overlay")
    if (existingOverlay) existingOverlay.remove()

    const overlay = document.createElement("div")
    overlay.id = "reset-parsing-loading-overlay"
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

    const messageContainer = document.createElement("div")
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

    const spinner = document.createElement("div")
    spinner.innerHTML = `
      <svg class="animate-spin" style="width: 32px; height: 32px; color: #ea580c;" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
      </svg>
    `

    const message = document.createElement("div")
    message.textContent = "Resetting parsing..."
    message.style.cssText = `
      font-size: 18px;
      font-weight: 500;
      color: #374151;
    `

    messageContainer.appendChild(spinner)
    messageContainer.appendChild(message)
    overlay.appendChild(messageContainer)

    if (!document.getElementById("reset-parsing-spinner-styles")) {
      const style = document.createElement("style")
      style.id = "reset-parsing-spinner-styles"
      style.textContent = `
        @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
        .animate-spin { animation: spin 1s linear infinite; }
      `
      document.head.appendChild(style)
    }

    document.body.appendChild(overlay)
  }
}
