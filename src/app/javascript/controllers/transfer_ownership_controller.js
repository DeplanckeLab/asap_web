import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "email",
    "option",
    "message",
    "messageText",
    "modal",
    "summary",
    "submitButton",
    "confirmButton"
  ]
  static values = { url: String, admin: Boolean }

  connect() {
    this.isProcessing = false
  }

  openConfirm(event) {
    event.preventDefault()
    this.hideMessage()

    const email = this.emailTarget.value.trim().toLowerCase()
    if (!this.validateEmail(email)) {
      this.showMessage("Enter a valid email address for an existing user account.", "error")
      return
    }

    if (this.adminValue) {
      const selected = this.selectedOptions()
      const optionLines = selected.length > 0
        ? selected.map((item) => "- " + item.label).join("\n")
        : "- Project only (related records keep their current owners)"

      this.summaryTarget.textContent =
        "Transfer ownership of this project to " + email + ".\n\n" +
        "Also transfer records currently owned by the current owner:\n" +
        optionLines +
        "\n\nYou will lose owner rights after this transfer. " +
        "If you still own records in the project, it will stay shared with you with Analyze access. " +
        "If you did not share the project with yourself, you will not be able to access this project anymore. " +
        "The new owner can remove your rights later. This cannot be undone."
    } else {
      this.summaryTarget.textContent =
        "Transfer ownership of this project to " + email + ".\n\n" +
        "The project and all attached records you currently own will move to the new owner.\n\n" +
        "If you did not share the project with yourself, you will not be able to access this project anymore. " +
        "The new owner can decide to remove your rights later. This cannot be undone."
    }

    this.pendingPayload = {
      email: email,
      confirm: true,
      transfer: this.adminValue ? this.transferPayload() : {}
    }
    this.modalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  close(event) {
    if (event) {
      event.preventDefault()
    }
    this.modalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  stop(event) {
    event.stopPropagation()
  }

  closeOnBackdrop(event) {
    if (event.target === this.modalTarget) {
      this.close()
    }
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && !this.modalTarget.classList.contains("hidden")) {
      this.close()
    }
  }

  toggleAll(event) {
    const checked = event.target.checked
    this.optionTargets.forEach((checkbox) => {
      checkbox.checked = checked
    })
  }

  async confirm(event) {
    event.preventDefault()
    if (this.isProcessing || !this.pendingPayload) {
      return
    }

    this.isProcessing = true
    this.setBusy(true)
    this.showMessage("Transferring ownership...", "info")

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": this.getCSRFToken()
        },
        body: JSON.stringify(this.pendingPayload)
      })

      const data = await response.json()
      if (response.ok && data.success) {
        this.close()
        this.showMessage(data.message || "Ownership transferred.", "success")
        const redirectUrl = data.redirect_url
        setTimeout(() => {
          window.location.href = redirectUrl || window.location.href
        }, 800)
        return
      }

      this.showMessage(data.error || "Failed to transfer ownership.", "error")
    } catch (error) {
      console.error("Ownership transfer error:", error)
      this.showMessage("Failed to transfer ownership. Please try again.", "error")
    } finally {
      this.isProcessing = false
      this.setBusy(false)
    }
  }

  selectedOptions() {
    return this.optionTargets
      .filter((checkbox) => checkbox.checked)
      .map((checkbox) => ({
        key: checkbox.value,
        label: checkbox.dataset.label || checkbox.value
      }))
  }

  transferPayload() {
    const payload = {}
    this.optionTargets.forEach((checkbox) => {
      payload[checkbox.value] = checkbox.checked
    })
    return payload
  }

  setBusy(busy) {
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = busy
    }
    if (this.hasConfirmButtonTarget) {
      this.confirmButtonTarget.disabled = busy
    }
  }

  showMessage(text, type) {
    if (!this.hasMessageTarget || !this.hasMessageTextTarget) return

    this.messageTarget.classList.remove("hidden")
    this.messageTextTarget.textContent = text
    this.messageTextTarget.classList.remove(
      "bg-green-100", "text-green-800",
      "bg-red-100", "text-red-800",
      "bg-blue-100", "text-blue-800",
      "bg-amber-100", "text-amber-800"
    )

    switch (type) {
      case "success":
        this.messageTextTarget.classList.add("bg-green-100", "text-green-800")
        break
      case "error":
        this.messageTextTarget.classList.add("bg-red-100", "text-red-800")
        break
      case "warning":
        this.messageTextTarget.classList.add("bg-amber-100", "text-amber-800")
        break
      default:
        this.messageTextTarget.classList.add("bg-blue-100", "text-blue-800")
    }
  }

  hideMessage() {
    if (this.hasMessageTarget) {
      this.messageTarget.classList.add("hidden")
    }
  }

  validateEmail(email) {
    const re = /^(([^<>()[\]\\.,;:\s@\"]+(\.[^<>()[\]\\.,;:\s@\"]+)*)|(\".+\"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\])|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$/
    return re.test(email)
  }

  getCSRFToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute("content") : ""
  }
}
