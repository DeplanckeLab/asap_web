import { Controller } from "@hotwired/stimulus"

// Sets project_type_id on legacy projects (ASAP version < 8) that have no type yet.
export default class extends Controller {
  static targets = ["select", "saveButton", "message", "messageText"]
  static values = {
    url: String
  }

  connect() {
    this.isProcessing = false
    this.updateSaveButtonState()
  }

  onChange() {
    this.hideMessage()
    this.updateSaveButtonState()
  }

  async save(event) {
    event.preventDefault()
    if (this.isProcessing) return

    const projectTypeId = this.selectTarget.value
    if (!projectTypeId) {
      this.showMessage('Please select a project type.', 'error')
      return
    }

    this.isProcessing = true
    this.saveButtonTarget.disabled = true
    this.showMessage('Saving...', 'info')

    let saved = false
    try {
      const response = await fetch(this.urlValue, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': this.getCSRFToken()
        },
        body: JSON.stringify({
          project: {
            project_type_id: projectTypeId
          }
        })
      })

      if (response.ok) {
        saved = true
        this.showMessage('Project type saved.', 'success')
        setTimeout(() => {
          window.location.reload()
        }, 1000)
        return
      }

      let errorMessage = 'Failed to save project type.'
      try {
        const data = await response.json()
        if (data.error) {
          errorMessage = data.error
        } else if (data.errors) {
          const messages = Array.isArray(data.errors)
            ? data.errors
            : Object.values(data.errors).flat()
          if (messages.length > 0) {
            errorMessage = messages.join(', ')
          }
        }
      } catch (_parseError) {
        // Keep the default error message when the response body is not JSON.
      }

      this.showMessage(errorMessage, 'error')
    } catch (error) {
      console.error('Project type save error:', error)
      this.showMessage('Failed to save project type. Please try again.', 'error')
    } finally {
      if (!saved) {
        this.isProcessing = false
        this.updateSaveButtonState()
      }
    }
  }

  updateSaveButtonState() {
    if (!this.hasSaveButtonTarget || !this.hasSelectTarget) return
    this.saveButtonTarget.disabled = this.isProcessing || !this.selectTarget.value
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
