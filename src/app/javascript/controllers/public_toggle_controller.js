import { Controller } from "@hotwired/stimulus"

// Handles toggling the public status of a project
// Requires compliance validation (as configured in Version env_json) to make public
export default class extends Controller {
  static targets = ["checkbox", "message", "messageText"]
  static values = {
    url: String,
    current: Boolean
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
    
    // If trying to make public, confirm with user
    if (newState && !this.currentValue) {
      const confirmed = confirm(
        'Are you sure you want to make this project public?\n\n' +
        'This will allow anyone to view and clone your project. ' +
        'Please ensure you have the rights to share this data publicly.'
      )
      
      if (!confirmed) {
        this.checkboxTarget.checked = false
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
        this.currentValue = data.public
        this.showMessage(data.message, 'success')
        
        // Reload page after short delay to show updated state
        setTimeout(() => {
          window.location.reload()
        }, 1500)
      } else {
        // Revert checkbox to previous state
        this.checkboxTarget.checked = this.currentValue
        
        // Show error message
        let errorMessage = data.error || 'Failed to update project status.'
        
        if (data.requires_validation) {
          errorMessage += ' Please run metadata schema validation first.'
        }
        
        this.showMessage(errorMessage, 'error')
      }
    } catch (error) {
      console.error('Toggle public error:', error)
      this.checkboxTarget.checked = this.currentValue
      this.showMessage('Failed to update project status. Please try again.', 'error')
    } finally {
      this.isProcessing = false
    }
  }

  showMessage(text, type) {
    if (!this.hasMessageTarget || !this.hasMessageTextTarget) return

    this.messageTarget.classList.remove('hidden')
    this.messageTextTarget.textContent = text

    // Remove existing type classes
    this.messageTextTarget.classList.remove(
      'bg-green-100', 'text-green-800',
      'bg-red-100', 'text-red-800',
      'bg-blue-100', 'text-blue-800',
      'bg-amber-100', 'text-amber-800'
    )

    // Add appropriate type classes
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
