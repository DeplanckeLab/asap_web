import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Coachmark pointing at the project compliance nav icon for projects whose
// origin is the standalone scFAIR validator. Activated from project_origin on
// the server; waits until parsing finishes, then shows once per project
// (sessionStorage) so later visits are not interrupted.
export default class extends Controller {
  static targets = ["navLink"]
  static values = {
    active: Boolean,
    iconUrl: String,
    projectId: Number,
    parsingComplete: Boolean
  }

  connect() {
    if (!this.activeValue) return
    if (this.alreadySeen()) return

    this.shown = false
    this.bubbleEl = null

    if (this.parsingCompleteValue) {
      this.showWhenReady()
      return
    }

    this.subscribeForParsingComplete()
  }

  disconnect() {
    this.unsubscribe()
    this.removeOutsideClickListener()
  }

  storageKey() {
    return `compliance-nav-hint-seen-${this.projectIdValue}`
  }

  alreadySeen() {
    try {
      return window.sessionStorage.getItem(this.storageKey()) === "1"
    } catch (_error) {
      return false
    }
  }

  markSeen() {
    try {
      window.sessionStorage.setItem(this.storageKey(), "1")
    } catch (_error) {
      // Ignore storage failures; worst case the hint can show again.
    }
  }

  subscribeForParsingComplete() {
    if (!this.projectIdValue || !consumer?.subscriptions) return

    this.subscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectIdValue },
      {
        received: (data) => this.handleStatusUpdate(data)
      }
    )
  }

  handleStatusUpdate(data) {
    if (!data) return
    const done =
      data.parsing_complete === true ||
      data.all_complete === true ||
      data.parsing_status === "success" ||
      data.parsing_status === "complete"
    if (!done) return
    this.unsubscribe()
    this.showWhenReady()
  }

  showWhenReady() {
    if (this.shown || this.alreadySeen()) return
    this.anchor = this.visibleNavLink()
    if (!this.anchor) {
      window.setTimeout(() => this.showWhenReady(), 250)
      return
    }
    this.shown = true
    this.markSeen()
    this.showBubble()
  }

  visibleNavLink() {
    const links = this.hasNavLinkTarget ? this.navLinkTargets : []
    return links.find((el) => el.offsetParent !== null) || links[0] || null
  }

  showBubble() {
    if (!this.anchor) return
    this.anchor.classList.add("compliance-nav-hint-target")
    this.buildBubble()

    this.outsideClickHandler = (event) => {
      if (this.element.contains(event.target)) return
      this.dismiss()
    }
    window.setTimeout(() => {
      document.addEventListener("click", this.outsideClickHandler)
    }, 0)

    this.anchor.addEventListener("click", () => this.dismiss(), { once: true })
  }

  buildBubble() {
    const bubble = document.createElement("div")
    bubble.className = "compliance-nav-hint-bubble"
    bubble.setAttribute("role", "dialog")
    bubble.setAttribute("aria-label", "Compliance tool hint")

    const iconHtml = this.iconUrlValue
      ? `<img src="${this.iconUrlValue}" alt="scFAIR" class="compliance-nav-hint-icon" />`
      : `<i class="fas fa-check-circle compliance-nav-hint-fa"></i>`

    bubble.innerHTML = `
      <div class="compliance-nav-hint-content">
        ${iconHtml}
        <p class="compliance-nav-hint-text">
          To open the tool that helps fix compliance issues, click this Compliance button in the menu.
        </p>
      </div>
      <button type="button" class="compliance-nav-hint-dismiss">
        Got it
      </button>
    `

    bubble.querySelector(".compliance-nav-hint-dismiss").addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.dismiss()
    })

    this.element.appendChild(bubble)
    this.bubbleEl = bubble
    this.positionBubble()
    window.requestAnimationFrame(() => this.positionBubble())
  }

  positionBubble() {
    if (!this.bubbleEl || !this.anchor) return
    const linkRect = this.anchor.getBoundingClientRect()
    const headerRect = this.element.getBoundingClientRect()
    const top = linkRect.bottom - headerRect.top + 8
    const left = linkRect.left - headerRect.left + (linkRect.width / 2)

    this.bubbleEl.style.top = `${top}px`
    this.bubbleEl.style.left = `${left}px`
    this.bubbleEl.style.transform = "translateX(-50%)"
  }

  dismiss(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    this.markSeen()
    if (this.anchor) {
      this.anchor.classList.remove("compliance-nav-hint-target")
    }
    if (this.bubbleEl) {
      this.bubbleEl.remove()
      this.bubbleEl = null
    }
    this.removeOutsideClickListener()
  }

  removeOutsideClickListener() {
    if (this.outsideClickHandler) {
      document.removeEventListener("click", this.outsideClickHandler)
      this.outsideClickHandler = null
    }
  }

  unsubscribe() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }
}
