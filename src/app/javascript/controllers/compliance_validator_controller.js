import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="compliance-validator"
export default class extends Controller {
  static targets = [
    "fileInput",
    "dropzone",
    "result",
    "status",
    "spinner",
    "submitButton"
  ]

  static values = {
    projectId: Number
  }

  connect() {
    this.subscription = null
    this.setupDropzoneHandlers()
    
    if (this.hasFileInputTarget) {
      this.fileInputTarget.addEventListener('change', this.handleFileSelect.bind(this))
    }
    
    // If we have a project ID, subscribe to compliance channel for real-time updates
    if (this.hasProjectIdValue && this.projectIdValue) {
      this.subscribeToCompliance(this.projectIdValue)
    }
  }

  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
  }

  setupDropzoneHandlers() {
    if (!this.hasDropzoneTarget) return

    const dropzone = this.dropzoneTarget

    dropzone.addEventListener('dragover', (e) => {
      e.preventDefault()
      e.stopPropagation()
      e.dataTransfer.dropEffect = 'copy'
      this.highlight()
      return false
    }, false)

    dropzone.addEventListener('dragenter', (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.highlight()
      return false
    }, false)

    dropzone.addEventListener('dragleave', (e) => {
      if (!dropzone.contains(e.relatedTarget)) {
        this.unhighlight()
      }
    }, false)

    dropzone.addEventListener('drop', (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.unhighlight()

      const files = e.dataTransfer.files
      if (files && files.length > 0) {
        this.validateFile(files[0])
      }

      return false
    }, false)
  }

  highlight() {
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.add('border-blue-500', 'bg-blue-50')
    }
  }

  unhighlight() {
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.remove('border-blue-500', 'bg-blue-50')
    }
  }

  handleFileSelect(e) {
    if (e.target.files && e.target.files.length > 0) {
      this.validateFile(e.target.files[0])
    }
  }

  async validateFile(file) {
    if (!file) return

    // Show loading state
    this.setStatus('Validating file...', 'info', true)
    
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
    }

    try {
      const formData = new FormData()
      formData.append('file', file)

      const csrfToken = document.querySelector('[name="csrf-token"]')?.content
      const response = await fetch('/compliance/validate_file', {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken
        },
        body: formData
      })

      const result = await response.json()

      if (!response.ok) {
        throw new Error(result.error || 'Validation failed')
      }

      this.displayResult(result)
      
    } catch (error) {
      console.error('Error validating file:', error)
      this.setStatus(`Error: ${error.message}`, 'error', false)
      this.displayError(error.message)
    } finally {
      if (this.hasSubmitButtonTarget) {
        this.submitButtonTarget.disabled = false
      }
    }
  }

  async validateProject(projectId) {
    if (!projectId) return

    this.setStatus('Starting validation...', 'info', true)
    
    // Subscribe to compliance channel for real-time updates
    this.subscribeToCompliance(projectId)

    try {
      const csrfToken = document.querySelector('[name="csrf-token"]')?.content
      const response = await fetch(`/compliance/projects/${projectId}/validate`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Accept': 'application/json'
        }
      })

      const result = await response.json()

      if (!response.ok) {
        throw new Error(result.error || 'Failed to start validation')
      }

      this.setStatus('Validation started. Please wait...', 'info', true)
      
    } catch (error) {
      console.error('Error starting validation:', error)
      this.setStatus(`Error: ${error.message}`, 'error', false)
    }
  }

  subscribeToCompliance(projectId) {
    if (!projectId) return
    
    // Unsubscribe from previous subscription if any
    if (this.subscription) {
      this.subscription.unsubscribe()
    }

    if (!consumer || !consumer.subscriptions) {
      console.error('[ComplianceValidator] ActionCable consumer is not available')
      return
    }

    try {
      this.subscription = consumer.subscriptions.create(
        { channel: "ComplianceChannel", project_id: projectId },
        {
          connected: () => {
            console.log(`[ComplianceValidator] Connected to ComplianceChannel for project ${projectId}`)
          },
          disconnected: () => {
            console.warn(`[ComplianceValidator] Disconnected from ComplianceChannel`)
          },
          rejected: () => {
            console.error(`[ComplianceValidator] Subscription rejected`)
          },
          received: (data) => {
            console.log('[ComplianceValidator] Received:', data)
            this.handleComplianceUpdate(data)
          }
        }
      )
    } catch (error) {
      console.error('[ComplianceValidator] Error creating subscription:', error)
    }
  }

  handleComplianceUpdate(data) {
    if (!data) return

    switch (data.status) {
      case 'started':
        this.setStatus('Validation in progress...', 'info', true)
        break
      case 'progress':
        this.setStatus(data.message || 'Processing...', 'info', true)
        break
      case 'completed':
        if (data.valid) {
          this.setStatus('Validation completed: Compliant', 'success', false)
        } else {
          const errorCount = data.errors_count || 0
          this.setStatus(`Validation completed: ${errorCount} error(s) found`, 'warning', false)
        }
        if (data.result) {
          this.displayResult(data.result)
        }
        // Reload page to show updated results if on project result page
        if (data.redirect_url) {
          window.location.href = data.redirect_url
        }
        break
      case 'failed':
        this.setStatus(`Validation failed: ${data.error || 'Unknown error'}`, 'error', false)
        break
    }
  }

  setStatus(message, variant = 'info', showSpinner = false) {
    if (!this.hasStatusTarget) return

    const statusEl = this.statusTarget
    const variants = {
      info: ['text-gray-700'],
      success: ['text-green-600'],
      error: ['text-red-600'],
      warning: ['text-yellow-600']
    }

    statusEl.textContent = message
    statusEl.classList.remove('text-gray-700', 'text-green-600', 'text-red-600', 'text-yellow-600')
    statusEl.classList.add(...(variants[variant] || variants.info))

    if (this.hasSpinnerTarget) {
      if (showSpinner) {
        this.spinnerTarget.classList.remove('hidden')
      } else {
        this.spinnerTarget.classList.add('hidden')
      }
    }
  }

  displayResult(result) {
    if (!this.hasResultTarget) return

    const valid = result.valid
    const errors = result.errors || []
    const warnings = result.warnings || []
    const info = result.info || []

    let html = ''

    // Summary
    html += `
      <div class="bg-white rounded-lg shadow-sm border ${valid ? 'border-green-200' : 'border-red-200'} p-4 mb-4">
        <div class="flex items-center justify-between">
          <h3 class="text-lg font-semibold ${valid ? 'text-green-800' : 'text-red-800'}">
            ${valid ? 'File is Compliant' : 'File is Not Compliant'}
          </h3>
          <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium ${valid ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800'}">
            ${errors.length} errors, ${warnings.length} warnings
          </span>
        </div>
      </div>
    `

    // Errors
    if (errors.length > 0) {
      html += `
        <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-4">
          <h4 class="text-red-800 font-semibold mb-2">Errors (${errors.length})</h4>
          <ul class="space-y-2">
      `
      errors.forEach(error => {
        const field = error.field || error['field'] || ''
        const message = error.message || error['message'] || ''
        html += `
          <li class="text-sm text-red-700">
            <code class="bg-red-100 px-1 rounded">${this.escapeHtml(field)}</code>: ${this.escapeHtml(message)}
          </li>
        `
      })
      html += '</ul></div>'
    }

    // Warnings
    if (warnings.length > 0) {
      html += `
        <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-4">
          <h4 class="text-yellow-800 font-semibold mb-2">Warnings (${warnings.length})</h4>
          <ul class="space-y-2">
      `
      warnings.forEach(warning => {
        const field = warning.field || warning['field'] || ''
        const message = warning.message || warning['message'] || ''
        html += `
          <li class="text-sm text-yellow-700">
            <code class="bg-yellow-100 px-1 rounded">${this.escapeHtml(field)}</code>: ${this.escapeHtml(message)}
          </li>
        `
      })
      html += '</ul></div>'
    }

    // Info (collapsible)
    if (info.length > 0) {
      html += `
        <details class="bg-blue-50 border border-blue-200 rounded-lg p-4">
          <summary class="text-blue-800 font-semibold cursor-pointer">
            Information (${info.length})
          </summary>
          <ul class="mt-2 space-y-2">
      `
      info.forEach(item => {
        const field = item.field || item['field'] || ''
        const message = item.message || item['message'] || ''
        html += `
          <li class="text-sm text-blue-700">
            <code class="bg-blue-100 px-1 rounded">${this.escapeHtml(field)}</code>: ${this.escapeHtml(message)}
          </li>
        `
      })
      html += '</ul></details>'
    }

    this.resultTarget.innerHTML = html
  }

  displayError(message) {
    if (!this.hasResultTarget) return

    this.resultTarget.innerHTML = `
      <div class="bg-red-50 border border-red-200 rounded-lg p-4">
        <h4 class="text-red-800 font-semibold">Validation Error</h4>
        <p class="text-sm text-red-700 mt-1">${this.escapeHtml(message)}</p>
      </div>
    `
  }

  escapeHtml(value) {
    if (value === null || value === undefined) return ''
    return String(value).replace(/[&<>"']/g, (char) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;'
    }[char]))
  }
}
