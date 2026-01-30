import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    annotId: Number,
    projectId: Number,
    url: String
  }

  connect() {
    console.log('Pipeline runs controller connected', {
      annotId: this.annotIdValue,
      url: this.urlValue
    })
    
    // Create floating card container if it doesn't exist (but keep it hidden)
    // Use a global flag to ensure we only create it once
    if (!window.pipelineRunsCardCreated) {
      this.createFloatingCard()
      window.pipelineRunsCardCreated = true
      const card = document.getElementById('pipeline-runs-card')
      if (card) {
        card.style.display = 'none'
        card.classList.add('hidden')
      }
    }
    
    // Add click outside handler only once
    if (!window.pipelineRunsClickHandlerAdded) {
      this.boundHandleClickOutside = this.handleClickOutside.bind(this)
      document.addEventListener('click', this.boundHandleClickOutside)
      window.pipelineRunsClickHandlerAdded = true
    }
  }
  
  disconnect() {
    // Remove click outside handler
    if (this.boundHandleClickOutside) {
      document.removeEventListener('click', this.boundHandleClickOutside)
    }
  }
  
  handleClickOutside(event) {
    const card = document.getElementById('pipeline-runs-card')
    if (!card) return
    
    // Check if click is outside the card and not on any pipeline-runs controller element
    const clickedElement = event.target
    const isClickOnCard = card.contains(clickedElement)
    const isClickOnPipelineBadge = clickedElement.closest('[data-controller*="pipeline-runs"]')
    
    if (!isClickOnCard && !isClickOnPipelineBadge) {
      if (card.style.display !== 'none' && !card.classList.contains('hidden')) {
        this.hidePipeline()
      }
    }
  }

  createFloatingCard() {
    // Check if card already exists
    let card = document.getElementById('pipeline-runs-card')
    if (card) {
      return
    }
    
    card = document.createElement('div')
    card.id = 'pipeline-runs-card'
    card.className = 'hidden fixed z-50 bg-white rounded-lg shadow-xl border border-gray-200'
    card.style.maxWidth = '600px'
    card.style.maxHeight = '80vh'
    card.style.overflow = 'hidden'
    card.style.display = 'none'
    card.style.flexDirection = 'column'
    card.style.left = '-9999px'
    card.style.top = '-9999px'
    
    const closeButton = document.createElement('button')
    closeButton.type = 'button'
    closeButton.className = 'text-gray-400 hover:text-gray-600 transition-colors cursor-pointer'
    closeButton.innerHTML = '<span class="text-xl">&times;</span>'
    closeButton.setAttribute('aria-label', 'Close')
    const self = this
    closeButton.addEventListener('click', function(e) {
      e.preventDefault()
      e.stopPropagation()
      self.hidePipeline(e)
    })
    
    const header = document.createElement('div')
    header.className = 'flex items-center justify-between px-4 py-3 border-b border-gray-200 bg-gray-50'
    header.style.cursor = 'move'
    header.style.userSelect = 'none'
    
    // Drag handle grip
    const dragHandle = document.createElement('div')
    dragHandle.className = 'flex items-center mr-2 text-gray-400 cursor-move hover:text-gray-600 transition-colors'
    dragHandle.style.flexShrink = '0'
    dragHandle.innerHTML = '<svg width="16" height="16" viewBox="0 0 12 12" fill="currentColor"><circle cx="2" cy="2" r="1"/><circle cx="6" cy="2" r="1"/><circle cx="10" cy="2" r="1"/><circle cx="2" cy="6" r="1"/><circle cx="6" cy="6" r="1"/><circle cx="10" cy="6" r="1"/><circle cx="2" cy="10" r="1"/><circle cx="6" cy="10" r="1"/><circle cx="10" cy="10" r="1"/></svg>'
    dragHandle.title = 'Drag to move'
    dragHandle.setAttribute('aria-label', 'Drag to move')
    
    const title = document.createElement('h3')
    title.className = 'text-lg font-semibold text-gray-900 flex-1'
    title.textContent = 'Pipeline Runs'
    
    header.appendChild(dragHandle)
    header.appendChild(title)
    header.appendChild(closeButton)
    
    // Make header draggable
    this.makeDraggable(card, header)
    
    const contentDiv = document.createElement('div')
    contentDiv.className = 'flex-1 overflow-y-auto p-4'
    contentDiv.id = 'pipeline-runs-content'
    contentDiv.innerHTML = '<div class="text-center text-gray-500 py-8">Click on an input matrix parameter to view its pipeline runs.</div>'
    
    card.appendChild(header)
    card.appendChild(contentDiv)
    
    document.body.appendChild(card)
    console.log('Pipeline runs card created')
  }

  showPipeline(event) {
    event.preventDefault()
    event.stopPropagation()
    
    console.log('showPipeline called', {
      annotId: this.annotIdValue,
      url: this.urlValue,
      element: this.element
    })
    
    const card = document.getElementById('pipeline-runs-card')
    if (!card) {
      console.log('Creating new card')
      this.createFloatingCard()
      const newCard = document.getElementById('pipeline-runs-card')
      if (newCard) {
        this.showCard(newCard, event)
      }
      return
    }
    
    this.showCard(card, event)
  }
  
  showCard(card, event) {
    const contentDiv = document.getElementById('pipeline-runs-content')
    if (contentDiv) {
      contentDiv.innerHTML = '<div class="text-center text-gray-500 py-8">Loading...</div>'
    }
    
    // Position the card near the clicked element
    const rect = event.currentTarget.getBoundingClientRect()
    const cardWidth = 600
    const cardHeight = Math.min(600, window.innerHeight * 0.8)
    
    // Calculate position - prefer right side, fallback to left if not enough space
    let left = rect.left + 10
    if (left + cardWidth > window.innerWidth - 20) {
      left = Math.max(20, rect.right - cardWidth - 10)
    }
    
    // Calculate top position - prefer below, fallback to above if not enough space
    let top = rect.bottom + 10
    if (top + cardHeight > window.innerHeight - 20) {
      top = Math.max(20, rect.top - cardHeight - 10)
    }
    
    card.style.left = `${left}px`
    card.style.top = `${top}px`
    card.style.width = `${cardWidth}px`
    card.style.display = 'flex'
    card.classList.remove('hidden')
    
    // Fetch pipeline runs (render as HTML partial)
    const url = `${this.urlValue}?annot_id=${this.annotIdValue}`
    
    fetch(url, {
      headers: {
        'Accept': 'text/html',
        'X-Requested-With': 'XMLHttpRequest'
      }
    })
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.text()
    })
    .then(html => {
      if (contentDiv) {
        contentDiv.innerHTML = html
      }
    })
    .catch(error => {
      console.error('Error fetching pipeline runs:', error)
      if (contentDiv) {
        contentDiv.innerHTML = `
          <div class="text-center text-red-600 py-8">
            <p class="font-semibold">Error loading pipeline runs</p>
            <p class="text-sm mt-2">${error.message}</p>
          </div>
        `
      }
    })
  }


  hidePipeline(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    
    const card = document.getElementById('pipeline-runs-card')
    if (card) {
      card.style.display = 'none'
      card.classList.add('hidden')
    }
  }
  
  makeDraggable(card, handle) {
    let isDragging = false
    let startX
    let startY
    let initialLeft
    let initialTop
    
    handle.addEventListener('mousedown', function(e) {
      // Only start dragging if clicking on the handle or header (not on close button)
      if (e.target.closest('button[aria-label="Close"]')) {
        return
      }
      
      isDragging = true
      startX = e.clientX
      startY = e.clientY
      
      // Get current position
      const rect = card.getBoundingClientRect()
      initialLeft = rect.left
      initialTop = rect.top
      
      card.style.transition = 'none'
      card.style.cursor = 'move'
      document.body.style.userSelect = 'none'
      
      e.preventDefault()
    })
    
    document.addEventListener('mousemove', function(e) {
      if (!isDragging) return
      
      const deltaX = e.clientX - startX
      const deltaY = e.clientY - startY
      
      let newLeft = initialLeft + deltaX
      let newTop = initialTop + deltaY
      
      // Constrain to viewport
      const rect = card.getBoundingClientRect()
      const maxX = window.innerWidth - rect.width
      const maxY = window.innerHeight - rect.height
      
      newLeft = Math.max(0, Math.min(newLeft, maxX))
      newTop = Math.max(0, Math.min(newTop, maxY))
      
      card.style.left = `${newLeft}px`
      card.style.top = `${newTop}px`
    })
    
    document.addEventListener('mouseup', function() {
      if (isDragging) {
        isDragging = false
        card.style.transition = ''
        card.style.cursor = ''
        document.body.style.userSelect = ''
      }
    })
  }
}

