import { Controller } from "@hotwired/stimulus"

// Handles starting publication, cancelling in-progress publication, or unpublishing.
// public flips only after H5AD export + scFAIR H5AD validation succeed.
export default class extends Controller {
  static targets = ["checkbox", "message", "messageText"]
  static values = {
    url: String,
    current: Boolean,
    beingPublished: Boolean
  }

  connect() {
    this.isProcessing = false
  }

  async toggle(event) {
    if (this.isProcessing) {
      event.preventDefault()
      return
    }

    const newState = this.checkboxTarget.checked
    const cancellingPublish = this.beingPublishedValue && !newState

    if (newState && !this.currentValue && !this.beingPublishedValue) {
      const confirmed = confirm(
        'Are you sure you want to publish this project?\n\n' +
        'The project stays private until H5AD export and scFAIR validation finish. ' +
        'Anyone will then be able to view and clone it. ' +
        'Please ensure you have the rights to share this data publicly.'
      )

      if (!confirmed) {
        this.checkboxTarget.checked = false
        return
      }
    }

    if (cancellingPublish) {
      const confirmed = confirm('Cancel publication in progress?')
      if (!confirmed) {
        this.checkboxTarget.checked = true
        return
      }
    }

    this.isProcessing = true
    this.showMessage('Processing...', 'info')

    try {
      const response = await fetch(this.urlValue, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': this.getCSRFToken()
        },
        body: JSON.stringify({
          public: newState
        })
      })

      const data = await response.json()

      if (response.ok && data.success) {
        this.currentValue = !!data.public
        this.beingPublishedValue = !!data.being_published
        this.checkboxTarget.checked = this.currentValue || this.beingPublishedValue
        this.showMessage(data.message || 'Updated.', data.being_published ? 'info' : 'success')

        setTimeout(() => {
          window.location.reload()
        }, 1500)
      } else {
        this.checkboxTarget.checked = this.currentValue || this.beingPublishedValue

        let errorMessage = data.error || 'Failed to update project status.'

        if (data.requires_validation) {
          errorMessage += ' Please run metadata schema validation first.'
        }

        this.showMessage(errorMessage, 'error')
      }
    } catch (error) {
      console.error('Toggle public error:', error)
      this.checkboxTarget.checked = this.currentValue || this.beingPublishedValue
      this.showMessage('Failed to update project status. Please try again.', 'error')
    } finally {
      this.isProcessing = false
    }
  }

  showMessage(text, type) {
    if (!this.hasMessageTarget || !this.hasMessageTextTarget) return

    this.messageTarget.classList.remove('hidden')
    this.messageTextTarget.textContent = text

    this.messageTextTarget.classList.remove(
      'bg-green-100', 'text-green-800',
      'bg-red-100', 'text-red-800',
      'bg-blue-100', 'text-blue-800',
      'bg-amber-100', 'text-amber-800'
    )

    switch (type) {
      case 'success':
        this.messageTextTarget.classList.add('bg-green-100', 'text-green-800')
        break
      case 'error':
        this.messageTextTarget.classList.add('bg-red-100', 'text-red-800')
        break
      case 'warning':
        this.messageTextTarget.classList.add('bg-amber-100', 'text-amber-800')
        break
      default:
        this.messageTextTarget.classList.add('bg-blue-100', 'text-blue-800')
    }
  }

  hideMessage() {
    if (this.hasMessageTarget) {
      this.messageTarget.classList.add('hidden')
    }
  }

  getCSRFToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute('content') : ''
  }
}
