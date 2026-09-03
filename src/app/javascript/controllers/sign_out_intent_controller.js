import { Controller } from "@hotwired/stimulus"

// Records a sign-out button gesture before Devise logout runs.
// Correlated server-side with DELETE /users/sign_out.
export default class extends Controller {
  announce(event) {
    if (!window.SESSION_DIAGNOSTICS) return
    if (this.submitted) return

    event.preventDefault()
    event.stopPropagation()
    this.submitted = true

    const form = this.element.form || this.element.closest("form")
    this.sendIntent()
      .catch((error) => {
        console.warn("[SessionDiag] sign_out_intent failed", error)
      })
      .finally(() => {
        if (form) form.requestSubmit()
      })
  }

  sendIntent() {
    const payload = JSON.stringify({
      source: "button_click",
      path: window.location.pathname,
      at: Date.now()
    })

    return fetch("/security/sign_out_intent", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Requested-With": "XMLHttpRequest",
        Accept: "application/json"
      },
      body: payload,
      credentials: "same-origin",
      keepalive: true
    }).then((response) => {
      console.info("[SessionDiag] sign_out_intent", response.status, window.location.pathname)
    })
  }
}
