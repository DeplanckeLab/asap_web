import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel", "overlay", "content"]
  static values = {
    formUrl: String,
    stepId: Number,
    projectId: Number
  }

  connect() {
    console.log('[SlideInFormController] Connected', {
      hasPanelTarget: this.hasPanelTarget,
      hasOverlayTarget: this.hasOverlayTarget,
      hasContentTarget: this.hasContentTarget,
      formUrl: this.formUrlValue,
      element: this.element
    })
    // Initialize contentLoaded flag
    this.contentLoaded = false
    
    // If targets are missing, create them dynamically
    if (!this.hasPanelTarget || !this.hasOverlayTarget || !this.hasContentTarget) {
      console.warn('[SlideInFormController] Targets missing on connect, creating them...')
      this.createTargetsIfMissing()
    }
    
    // Close on escape key
    document.addEventListener('keydown', this.handleEscape.bind(this))
  }

  createTargetsIfMissing() {
    // Create overlay if missing
    if (!this.hasOverlayTarget) {
      const overlay = document.createElement('div')
      overlay.setAttribute('data-slide-in-form-target', 'overlay')
      overlay.className = 'fixed inset-0 bg-black bg-opacity-50 z-50 hidden transition-opacity duration-300'
      overlay.setAttribute('data-action', 'click->slide-in-form#overlayClick')
      overlay.style.display = 'none'
      this.element.appendChild(overlay)
      console.log('[SlideInFormController] Created overlay target')
    }

    // Create panel if missing
    if (!this.hasPanelTarget) {
      const panel = document.createElement('div')
      panel.setAttribute('data-slide-in-form-target', 'panel')
      panel.className = 'fixed top-0 right-0 h-full w-full max-w-2xl bg-white shadow-2xl z-50 hidden overflow-y-auto transition-transform duration-300 ease-out'
      panel.style.display = 'none'
      panel.style.transform = 'translateX(100%)'
      
      // Create panel header
      const header = document.createElement('div')
      header.className = 'sticky top-0 bg-white border-b border-gray-200 px-6 py-4 z-10 flex items-center justify-between'
      header.style.background = 'linear-gradient(to right, #eff6ff, #eef2ff)'
      header.style.backgroundColor = '#ffffff'
      
      const title = document.createElement('h3')
      title.className = 'text-lg font-semibold text-gray-900'
      title.textContent = 'New Run'
      header.appendChild(title)
      
      const closeBtn = document.createElement('button')
      closeBtn.type = 'button'
      closeBtn.className = 'text-gray-500 hover:text-gray-700 transition-colors'
      closeBtn.setAttribute('data-action', 'click->slide-in-form#close')
      closeBtn.innerHTML = '<i class="fas fa-times text-xl"></i>'
      header.appendChild(closeBtn)
      
      panel.appendChild(header)
      
      // Create content container
      const content = document.createElement('div')
      content.setAttribute('data-slide-in-form-target', 'content')
      content.className = 'p-6'
      panel.appendChild(content)
      
      this.element.appendChild(panel)
      console.log('[SlideInFormController] Created panel and content targets')
      
      // Trigger Stimulus scan to recognize new targets
      if (window.Stimulus && window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
        setTimeout(() => {
          window.Stimulus.router.scan()
        }, 0)
      }
    }
  }

  disconnect() {
    document.removeEventListener('keydown', this.handleEscape.bind(this))
  }

  handleEscape(event) {
    if (event.key === 'Escape' && this.isOpen()) {
      this.close()
    }
  }

  open() {
    console.log('[SlideInFormController] open() called', {
      hasPanelTarget: this.hasPanelTarget,
      hasOverlayTarget: this.hasOverlayTarget,
      hasContentTarget: this.hasContentTarget,
      contentLoaded: this.contentLoaded
    })
    
    // Check if targets exist, if not create them
    if (!this.hasPanelTarget || !this.hasOverlayTarget || !this.hasContentTarget) {
      console.warn('[SlideInFormController] Targets missing in open(), creating them...')
      this.createTargetsIfMissing()
      
      // Re-check after creation
      if (!this.hasPanelTarget || !this.hasOverlayTarget || !this.hasContentTarget) {
        console.error('[SlideInFormController] Failed to create targets!', {
          hasPanelTarget: this.hasPanelTarget,
          hasOverlayTarget: this.hasOverlayTarget,
          hasContentTarget: this.hasContentTarget
        })
        // Try one more time with a small delay for Stimulus to recognize them
        setTimeout(() => {
          if (this.hasPanelTarget && this.hasOverlayTarget && this.hasContentTarget) {
            console.log('[SlideInFormController] Targets found after delay, retrying open...')
            this.open()
          } else {
            alert('Error: Form panel not available. Please refresh the page.')
          }
        }, 100)
        return
      }
    }
    
    // Load form content if not already loaded
    if (!this.contentLoaded) {
      this.loadFormContent()
    } else {
      this.showPanel()
    }
  }

  close() {
    if (!this.hasPanelTarget || !this.hasOverlayTarget) return
    
    this.panelTarget.style.transform = 'translateX(100%)'
    this.overlayTarget.style.opacity = '0'
    
    setTimeout(() => {
      this.panelTarget.style.display = 'none'
      this.overlayTarget.style.display = 'none'
      document.body.style.overflow = ''
    }, 300)
  }

  showPanel() {
    this.panelTarget.style.display = 'block'
    this.overlayTarget.style.display = 'block'
    document.body.style.overflow = 'hidden'
    
    // Trigger animation
    requestAnimationFrame(() => {
      this.panelTarget.style.transform = 'translateX(0)'
      this.overlayTarget.style.opacity = '1'
    })
  }

  async loadFormContent() {
    if (!this.formUrlValue) {
      console.error('[SlideInFormController] formUrl value is missing')
      return
    }

    if (this.contentTarget) {
      this.contentTarget.innerHTML = '<div class="flex items-center justify-center p-8"><i class="fas fa-spinner fa-spin text-blue-600 text-2xl"></i></div>'
    }

    try {
      const response = await fetch(this.formUrlValue, {
        headers: {
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'text/html'
        }
      })
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      const html = await response.text()
      
      if (this.contentTarget) {
        this.contentTarget.innerHTML = html
      }
      
      // Trigger Stimulus to scan for new controllers in the loaded content
      if (window.Stimulus) {
        console.log('[SlideInFormController] Triggering Stimulus scan for new controllers...')
        try {
          // Use setTimeout to ensure DOM is fully updated
          setTimeout(() => {
            // Manually scan using Stimulus's router
            if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
              console.log('[SlideInFormController] Calling Stimulus router.scan()')
              window.Stimulus.router.scan()
            }
            
            // Check for form-req controller after a short delay
            setTimeout(() => {
              const formReqElement = this.contentTarget.querySelector('[data-controller*="form-req"]')
              if (formReqElement) {
                console.log('[SlideInFormController] Found form-req element')
                const formReqController = window.Stimulus.getControllerForElementAndIdentifier(formReqElement, 'form-req')
                if (!formReqController) {
                  console.warn('[SlideInFormController] form-req controller NOT connected yet')
                  // Try scanning again
                  if (window.Stimulus.router && typeof window.Stimulus.router.scan === 'function') {
                    window.Stimulus.router.scan()
                  }
                } else {
                  console.log('[SlideInFormController] form-req controller IS connected')
                }
              } else {
                console.log('[SlideInFormController] No form-req element found in loaded content')
              }
            }, 100)
          }, 0)
        } catch (e) {
          console.warn('[SlideInFormController] Error triggering Stimulus scan:', e)
        }
      }
      
      this.contentLoaded = true
      this.showPanel()
    } catch (error) {
      console.error('[SlideInFormController] Error loading form:', error)
      if (this.contentTarget) {
        this.contentTarget.innerHTML = `
          <div class="p-8 text-center">
            <i class="fas fa-exclamation-circle text-red-600 text-2xl mb-4"></i>
            <p class="text-red-800">Error loading form. Please try again.</p>
          </div>
        `
      }
    }
  }

  isOpen() {
    return this.hasPanelTarget && this.panelTarget.style.display === 'block'
  }

  // Handle overlay click to close
  overlayClick(event) {
    if (event.target === this.overlayTarget) {
      this.close()
    }
  }
}

