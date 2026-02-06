// GeneManager - Handles gene autocomplete and expression visualization
export class GeneManager {
  constructor(controller) {
    this.controller = controller
    this.autocompleteData = null
    this.currentMatches = []
    this.selectedGene = null
    this.projectIdentifier = null
    this.geneTags = [] // Array of {symbol, ensemblId, stableId, query}
    this.notFoundQueries = [] // Queries that didn't match
    this.geneExpressionData = {} // Store expression values per gene: {stableId: {values: [...], stats: {...}}}
    this.currentMatrixLayer = '/matrix' // Default to /matrix
    this.currentMatrixAnnotId = null // Annot ID for the current matrix/layer
    this.matrixInitialized = false
    this.autocompleteLoaded = false
    this.geneSearchVisible = false
    this.geneSearchVisibilityTimer = null
    this.defaultGeneTagsDisplay = null
    this.defaultMatrixSelectionDisplay = null
    this.matrixSelectionWrapper = null
    // Expose globally for diagnostics and inline handlers
    window.geneManager = this
    // console.log('GeneManager: Constructor initialized, window.geneManager set')
    this.init()
  }

  // Base metadata key (without layer/annotId)
  getBaseGeneMetadataId(geneId) {
    return `gene_${geneId}`
  }

  // Generate gene metadata ID for specific annot_id (defaults to current layer)
  getGeneMetadataId(geneId, annotId = null) {
    const baseKey = this.getBaseGeneMetadataId(geneId)
    const resolvedAnnotId = annotId !== null ? annotId : this.currentMatrixAnnotId
    if (resolvedAnnotId && resolvedAnnotId !== '') {
      return `${baseKey}_${resolvedAnnotId}`
    }
    return baseKey
  }

  getGeneMetadataKeys(geneId, annotId = null) {
    const baseKey = this.getBaseGeneMetadataId(geneId)
    const layerKey = this.getGeneMetadataId(geneId, annotId)
    return { baseKey, layerKey }
  }

  // Handle matrix/layer selection change
  async onMatrixLayerChange(layerPath, annotId) {
    const previousLayer = this.currentMatrixLayer
    const previousAnnotId = this.currentMatrixAnnotId
    const nextLayer = layerPath || '/matrix'
    const nextAnnotId = annotId && annotId !== '' ? String(annotId) : null
    const initialGeneCount = this.geneTags?.length || 0
    // console.log('GeneManager: applying matrix change', {
      // previousLayer,
      // previousAnnotId,
      // nextLayer,
      // nextAnnotId,
      // genes: initialGeneCount
    // })
    this.currentMatrixLayer = nextLayer
    this.currentMatrixAnnotId = nextAnnotId
    this.matrixInitialized = true
    
    // Clear all gene expression data vectors with old annot_id
    if (this.controller && this.controller.loadedMetadataVectors) {
      const keysToRemove = Object.keys(this.controller.loadedMetadataVectors).filter(key => key.startsWith('gene_'))

      keysToRemove.forEach(key => delete this.controller.loadedMetadataVectors[key])
      // console.log('GeneManager: cleared cached vectors', { removed: keysToRemove.length })
    } else {
      // console.log('GeneManager: no cached vectors to clear')
    }
    
    // Clear cached gene expression data
    this.geneExpressionData = {}
    
    // Clear inline range slider data for genes
    if (this.controller && this.controller.inlineRangeSliderData) {
      const sliderKeysToRemove = Object.keys(this.controller.inlineRangeSliderData).filter(key => key.startsWith('gene_'))

      sliderKeysToRemove.forEach(key => delete this.controller.inlineRangeSliderData[key])
      // console.log('GeneManager: cleared slider caches', { removed: sliderKeysToRemove.length })
    } else {
      // console.log('GeneManager: no slider cache to clear')
    }
    
    const genesToReload = new Map()
    const addGeneDescriptor = (stableId, symbol = null, ensembl = '', query = null) => {
      if (!stableId) return
      const stableIdStr = String(stableId)
      const stableIdNum = Number(stableId)
      const key = stableIdStr
      if (genesToReload.has(key)) return
      genesToReload.set(key, {
        stableId: isNaN(stableIdNum) ? stableIdStr : stableIdNum,
        symbol: symbol || `Gene ${stableIdStr}`,
        ensemblId: ensembl || '',
        query: query || symbol || stableIdStr
      })
    }

    if (Array.isArray(this.geneTags)) {
      this.geneTags.forEach(gene => addGeneDescriptor(gene.stableId, gene.symbol, gene.ensemblId, gene.query))
    }

    const collectFromButton = (buttonInfo) => {
      if (!buttonInfo || !buttonInfo.isGene) return
      const buttonEl = buttonInfo.button
      const stableId = buttonEl?.dataset?.geneId || buttonInfo.metadataId
      const symbol = buttonInfo.metadataName || buttonEl?.dataset?.geneName
      addGeneDescriptor(stableId, symbol)
    }

    collectFromButton(this.controller?.selectedXButton)
    collectFromButton(this.controller?.selectedYButton)

    const currentVectorId = this.controller?.currentMetadataVector?.id
    if (currentVectorId && typeof currentVectorId === 'string' && currentVectorId.startsWith('gene_')) {
      const parts = currentVectorId.split('_')
      if (parts.length >= 2) {
        addGeneDescriptor(parts[1])
      }
    }

    if (genesToReload.size > 0) {
      // console.log('GeneManager: reloading genes for new layer', { genes: genesToReload.size })
      const resultsDiv = document.getElementById('gene-expression-results')
      const reloadPromises = Array.from(genesToReload.values()).map(gene => this.loadGeneExpressionData(gene, resultsDiv))
      await Promise.all(reloadPromises)
    } else {
      // console.log('GeneManager: no genes to reload for new layer')
    }

    // Refresh custom 2D plot if open
    if (this.controller?.customPlotManager) {
      await this.controller.customPlotManager.refresh2DPlotIfOpen()
    }
  }

  initializeGeneSearchUI(tagsContainer, input) {
    if (!this.defaultGeneTagsDisplay || this.defaultGeneTagsDisplay === 'none') {
      this.defaultGeneTagsDisplay = tagsContainer.style.display && tagsContainer.style.display !== 'none'
        ? tagsContainer.style.display
        : 'flex'
    }
    tagsContainer.style.display = 'none'
    input.setAttribute('disabled', 'disabled')

    const matrixLink = document.getElementById('matrix-selection-link')
    if (matrixLink) {
      const wrapper = matrixLink.parentElement
      if (wrapper) {
        this.matrixSelectionWrapper = wrapper
        if (!this.defaultMatrixSelectionDisplay || this.defaultMatrixSelectionDisplay === 'none') {
          this.defaultMatrixSelectionDisplay = wrapper.style.display && wrapper.style.display !== 'none'
            ? wrapper.style.display
            : 'flex'
        }
        wrapper.style.display = 'none'
      }
    }

    this.updateGeneSearchAvailabilityMessage('Loading gene data…')
    this.startGeneSearchVisibilityWatcher()
    this.updateGeneSearchVisibility()
  }

  startGeneSearchVisibilityWatcher() {
    if (this.geneSearchVisibilityTimer) return
    this.geneSearchVisibilityTimer = setInterval(() => {
      this.updateGeneSearchVisibility()
    }, 500)
  }

  resolveVisualizationController() {
    if (this.controller?.application) {
      const visualizationElement = document.querySelector('[data-controller="visualization"]')
      if (visualizationElement) {
        const domController = this.controller.application.getControllerForElementAndIdentifier(visualizationElement, 'visualization')
        if (domController) {
          return domController
        }
      }
    }
    if (window.visualizationController) {
      return window.visualizationController
    }
    return this.controller || null
  }

  clearGeneSearchAvailabilityMessage() {
    const statusDiv = document.getElementById('gene-input-status')
    const statusTextDiv = document.getElementById('gene-input-status-text')
    if (!statusDiv || !statusTextDiv) return

    statusDiv.style.display = 'none'
    statusDiv.style.backgroundColor = ''
    statusDiv.style.border = ''
    statusDiv.style.padding = ''
    statusTextDiv.textContent = ''
    delete statusDiv.dataset.statusType
  }

  hideGeneAvailabilityMessage() {
    const statusDiv = document.getElementById('gene-input-status')
    if (!statusDiv) return
    statusDiv.classList.add('gene-loading-hidden')
    statusDiv.dataset.statusLocked = 'true'
    statusDiv.style.display = 'none'
  }

  updateGeneSearchAvailabilityMessage(message) {
    const statusDiv = document.getElementById('gene-input-status')
    const statusTextDiv = document.getElementById('gene-input-status-text')
    if (!statusDiv || !statusTextDiv) return

    const normalizedMessage = typeof message === 'string' ? message.trim().toLowerCase() : ''
    const isLoadingMessage = normalizedMessage === 'loading gene data…' ||
      normalizedMessage === 'loading gene data...' ||
      normalizedMessage === 'loading gene data' ||
      normalizedMessage === 'loading genes…' ||
      normalizedMessage === 'loading genes...' ||
      normalizedMessage === 'loading genes'
    if (statusDiv.dataset.statusLocked === 'true' && isLoadingMessage) {
      return
    }
    const shouldSuppress = !message ||
      normalizedMessage === '' ||
      (isLoadingMessage && this.geneSearchVisible)
    
    if (shouldSuppress) {
      this.clearGeneSearchAvailabilityMessage()
      return
    }

    if (message) {
      statusDiv.dataset.statusType = 'availability'
      statusDiv.style.backgroundColor = 'transparent'
      statusDiv.style.border = 'none'
      statusDiv.style.padding = '0'
      statusTextDiv.innerHTML = `
        <span style="
          display: inline-flex;
          align-items: center;
          gap: 8px;
          font-style: italic;
          color: #111827;
        ">
          <span style="
            width: 16px;
            height: 16px;
            border: 2px solid #4b5563;
            border-top-color: transparent;
            border-radius: 50%;
            display: inline-block;
            animation: gm-spinner 0.75s linear infinite;
          "></span>
          ${message}
        </span>
      `
      this.injectSpinnerKeyframes()
      statusDiv.style.display = 'block'
    } else if (statusDiv.dataset.statusType === 'availability') {
      statusDiv.style.display = 'none'
      statusDiv.style.backgroundColor = ''
      statusDiv.style.border = ''
      statusDiv.style.padding = ''
      statusTextDiv.textContent = ''
      delete statusDiv.dataset.statusType
    }
  }

  injectSpinnerKeyframes() {
    if (document.getElementById('gm-spinner-keyframes')) return
    const style = document.createElement('style')
    style.id = 'gm-spinner-keyframes'
    style.textContent = `
      @keyframes gm-spinner {
        from { transform: rotate(0deg); }
        to { transform: rotate(360deg); }
      }
    `
    document.head.appendChild(style)
  }

  updateGeneSearchVisibility() {
    const tagsContainer = document.getElementById('gene-tags-container')
    const input = document.getElementById('gene-autocomplete-input')
    if (!tagsContainer || !input) return

    const resolvedController = this.resolveVisualizationController()
    if (resolvedController && resolvedController !== this.controller) {
      this.controller = resolvedController
    }

    const ready = this.autocompleteLoaded && this.isRendererReadyForGeneSearch(this.controller)

    if (ready) {
      if (!this.geneSearchVisible) {
        this.hideGeneAvailabilityMessage()
        tagsContainer.style.display = this.defaultGeneTagsDisplay || 'flex'
        input.removeAttribute('disabled')
        this.geneSearchVisible = true
        if (this.matrixSelectionWrapper) {
          this.matrixSelectionWrapper.style.display = this.defaultMatrixSelectionDisplay || 'flex'
        }
      } else {
        this.clearGeneSearchAvailabilityMessage()
      }
      if (this.geneSearchVisibilityTimer) {
        clearInterval(this.geneSearchVisibilityTimer)
        this.geneSearchVisibilityTimer = null
      }
    } else {
      if (this.geneSearchVisible) {
        tagsContainer.style.display = 'none'
        input.setAttribute('disabled', 'disabled')
        this.geneSearchVisible = false
        if (this.matrixSelectionWrapper) {
          this.matrixSelectionWrapper.style.display = 'none'
        }
      }
      this.updateGeneSearchAvailabilityMessage('Loading genes…')
    }
  }

  isRendererReadyForGeneSearch(controller) {
    if (!controller) return false
    const renderer = controller.reglRenderer
    const hasRendererState = !!(renderer && (
      (typeof renderer.numPoints === 'number' && renderer.numPoints > 0) ||
      (renderer.positions && renderer.positions.length > 0) ||
      (renderer.colors && renderer.colors.length > 0)
    ))
    const hasCoordinates = Array.isArray(controller.currentCoordinates) && controller.currentCoordinates.length > 0
    let canvasVisible = false
    if (controller.canvas && controller.canvas.parentElement) {
      const parent = controller.canvas.parentElement
      canvasVisible = parent.offsetWidth > 0 && parent.offsetHeight > 0
    }
    if (!canvasVisible) {
      const plotContainer = document.querySelector('.plot-container')
      canvasVisible = !!(plotContainer && plotContainer.offsetWidth > 0 && plotContainer.offsetHeight > 0)
    }
    return canvasVisible && (hasRendererState || hasCoordinates)
  }

  init() {
    // console.log('GeneManager: Initializing...')
    // Extract project identifier from URL (could be ID, key, or public_id like ASAP49)
    const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
    if (pathMatch) {
      this.projectIdentifier = pathMatch[1] // Use identifier instead of just ID
      // console.log('GeneManager: Project identifier extracted:', this.projectIdentifier)
    } else {
      console.warn('GeneManager: Could not extract project identifier from URL:', window.location.pathname)
    }
    
    // Check if user is admin from data attribute
    const visualizationElement = document.querySelector('[data-controller="visualization"]')
    this.isAdmin = visualizationElement && visualizationElement.dataset.isAdmin === 'true'
    // console.log('GeneManager: Is admin:', this.isAdmin)

    // Setup combined input field with tags
    const input = document.getElementById('gene-autocomplete-input')
    const tagsContainer = document.getElementById('gene-tags-container')
    if (input && tagsContainer) {
      // console.log('GeneManager: Combined input field found, setting up listeners')
      let debounceTimer = null
      this.initializeGeneSearchUI(tagsContainer, input)
      
      // Render initial tags (input is already in container from HTML)
      this.renderGeneTags()
      
      input.addEventListener('input', (e) => {
        const value = e.target.value
        // console.log('GeneManager: Input event triggered, value:', value)
        
        // Check for separators (comma, space, newline) to process completed genes
        const separatorMatch = value.match(/[,,\s\n]+/)
        if (separatorMatch && value.trim().length > 0) {
          // Process everything before the separator
          const parts = value.split(/[,,\s\n]+/)
          const lastPart = parts.pop() // Keep the last part for autocomplete
          
          // Process completed genes
          for (const part of parts) {
            const trimmed = part.trim()
            if (trimmed) {
              this.processGeneInput(trimmed)
            }
          }
          
          // Update input to only show the current typing part
          input.value = lastPart.trim()
        }
        
        // Handle autocomplete for current input
        clearTimeout(debounceTimer)
        debounceTimer = setTimeout(() => {
          this.handleInput(value.trim())
        }, 300) // Debounce for 300ms
      })

      input.addEventListener('keydown', (e) => {
        // Enter key: process current input if not empty
        if (e.key === 'Enter' && input.value.trim()) {
          e.preventDefault()
          this.processGeneInput(input.value.trim())
          input.value = ''
          this.hideDropdown()
        }
        
        // Backspace on empty input: remove last tag
        if (e.key === 'Backspace' && input.value === '' && this.geneTags.length > 0) {
          e.preventDefault()
          this.removeGeneTag(this.geneTags.length - 1)
        }
      })

      input.addEventListener('focus', () => {
        // console.log('GeneManager: Input focused, current value:', input.value)
        if (input.value.trim() && this.currentMatches.length > 0) {
          this.showDropdown()
        }
      })
      
      // Handle paste events for bulk input
      input.addEventListener('paste', (e) => {
        setTimeout(() => {
          const pastedText = input.value
          const genes = this.parseBulkGeneInput(pastedText)
          input.value = ''
          
          // Process all pasted genes and track found/not found
          this.processBulkGeneInput(genes)
        }, 10)
      })

    } else {
      console.error('GeneManager: Input field or tags container not found!')
    }

    // Close dropdown when clicking outside
    document.addEventListener('click', (e) => {
      // Don't process clicks on modal elements or modal buttons
      const modalOverlay = document.getElementById('gene-set-modal-overlay')
      if (modalOverlay && modalOverlay.contains(e.target)) {
        return
      }
      // Also check for any element with high z-index (modal)
      const highZIndexParent = e.target.closest('[style*="z-index: 10000"]')
      if (highZIndexParent) {
        return
      }
      
      // Check if click is on modal buttons
      const closeBtn = document.getElementById('close-add-gene-set-modal')
      const cancelBtn = document.getElementById('cancel-add-gene-set-btn')
      if (closeBtn && (e.target === closeBtn || closeBtn.contains(e.target))) {
        return
      }
      if (cancelBtn && (e.target === cancelBtn || cancelBtn.contains(e.target))) {
        return
      }
      
      const dropdown = document.getElementById('gene-autocomplete-dropdown')
      const input = document.getElementById('gene-autocomplete-input')
      if (dropdown && input && !dropdown.contains(e.target) && !input.contains(e.target)) {
        this.hideDropdown()
      }
    }, false) // Use bubbling phase so modal handlers fire first

    // Load autocomplete data on page load
    if (this.projectIdentifier) {
      // console.log('GeneManager: Loading autocomplete data on initialization...')
      this.loadAutocompleteData()
    }

    // Initialize gene tags and results
    this.geneTags = []
    this.notFoundQueries = []
    this.totalGeneCount = 0 // Store total gene count for badge
    
    // Initialize add gene set button - use a bound function to ensure correct context
    const addBtn = document.getElementById('add-gene-set-btn')
    if (addBtn) {
      // Store reference to this for the event handler
      const geneManager = this
      addBtn.addEventListener('click', function(e) {
        e.preventDefault()
        e.stopPropagation()
        
        // Check for gene divs in the DOM instead of geneTags array
        const resultsDiv = document.getElementById('gene-expression-results')
        const geneDivs = resultsDiv ? resultsDiv.querySelectorAll('[id^="gene-result-"]') : []
        const geneCount = geneDivs.length
        
        // console.log('GeneManager: Add button clicked, found', geneCount, 'gene divs in DOM')
        
        if (geneCount === 0) {
          alert('No genes selected. Please select genes before creating a gene set.')
          return
        }
        
        // Extract gene data from the DOM divs
        const genes = Array.from(geneDivs).map(div => {
          const stableId = div.id.replace('gene-result-', '')
          const geneSymbolEl = div.querySelector('h3')
          const geneSymbol = geneSymbolEl ? geneSymbolEl.textContent.trim().split(' ')[0] : ''
          // Try to extract ensembl ID and stable ID from the DOM
          const stableIdMatch = div.textContent.match(/Stable ID[:\s]+(\d+)/)
          const ensemblMatch = div.textContent.match(/(FBgn\d+)/)
          return {
            symbol: geneSymbol,
            ensemblId: ensemblMatch ? ensemblMatch[1] : '',
            stableId: parseInt(stableIdMatch ? stableIdMatch[1] : stableId),
            query: geneSymbol
          }
        })
        
        geneManager.showAddGeneSetModalWithGenes(genes)
      })
    }
  }

  updateGeneCountBadge() {
    const badge = document.getElementById('gene-count-badge')
    if (badge) {
      const selectedCount = this.geneTags.length
      if (this.totalGeneCount && this.totalGeneCount > 0) {
        badge.textContent = `${selectedCount} / ${this.totalGeneCount.toLocaleString()}`
        badge.style.backgroundColor = selectedCount > 0 ? '#dbeafe' : '#e5e7eb'
        badge.style.color = selectedCount > 0 ? '#1e40af' : '#374151'
        badge.style.display = 'inline-flex'
      } else {
        badge.textContent = `${selectedCount} / -`
        badge.style.backgroundColor = '#e5e7eb'
        badge.style.color = '#374151'
        badge.style.display = 'inline-flex'
      }
    }
    
    // Update the add gene set button visibility
    const addBtn = document.getElementById('add-gene-set-btn')
    if (addBtn) {
      addBtn.style.display = this.geneTags.length > 0 ? 'inline-flex' : 'none'
    }
  }

  async loadAutocompleteData(runId = null) {
    // console.log('GeneManager: loadAutocompleteData called, runId:', runId)
    if (!this.projectIdentifier) {
      console.warn('GeneManager: No project identifier found')
      return
    }

    try {
      // Try run-specific file first if run_id is provided
      let url = null
      let data = null

      if (runId) {
        url = `/projects/${encodeURIComponent(this.projectIdentifier)}/get_file?filename=autocomplete_genes.json&step=cell_filtering&run_id=${encodeURIComponent(runId)}&display=true`
        // console.log('GeneManager: Attempting to load run-specific file:', url)
        try {
          const response = await fetch(url)
          // console.log('GeneManager: Run-specific response status:', response.status, 'ok:', response.ok)
          if (response.ok) {
            const contentType = response.headers.get('content-type')
            // console.log('GeneManager: Run-specific content-type:', contentType)
            if (contentType && contentType.includes('application/json')) {
              data = await response.json()
              // console.log('GeneManager: Run-specific data loaded, has search:', !!data.search, 'search length:', data.search?.length)
            } else {
              console.warn('GeneManager: Run-specific response is not JSON, content-type:', contentType)
            }
          } else {
            console.warn('GeneManager: Run-specific response not OK, status:', response.status)
          }
        } catch (e) {
          console.warn('GeneManager: Failed to load run-specific autocomplete file:', e)
        }
      }

      // Fall back to parsing directory file if run-specific file not found
      if (!data || !data.search) {
        url = `/projects/${encodeURIComponent(this.projectIdentifier)}/get_file?filename=autocomplete_genes.json&step=parsing&display=true`
        // console.log('GeneManager: Attempting to load parsing file:', url)
        try {
          const response = await fetch(url, {
            method: 'GET',
            credentials: 'same-origin',
            headers: {
              'Accept': 'application/json'
            }
          })
          // console.log('GeneManager: Parsing response status:', response.status, 'ok:', response.ok)
          if (response.ok) {
            const contentType = response.headers.get('content-type')
            // console.log('GeneManager: Parsing content-type:', contentType)
            
            // Read response as text first, then parse as JSON
            // This avoids "Body has already been consumed" error
            const text = await response.text()
            try {
              data = JSON.parse(text)
              // console.log('GeneManager: Parsing data loaded as JSON, has search:', !!data.search, 'search length:', data.search?.length)
            } catch (jsonError) {
              console.warn('GeneManager: Failed to parse response as JSON:', jsonError)
              // console.log('GeneManager: Parsing response text (first 500 chars):', text.substring(0, 500))
            }
            
            // Check if content-type was not JSON but we got JSON data
            if (!contentType || !contentType.includes('application/json')) {
              if (data && typeof data === 'object') {
                console.warn('GeneManager: Got JSON data but content-type was:', contentType, '- proceeding anyway')
              }
            }
          } else {
            console.warn('GeneManager: Parsing response not OK, status:', response.status, response.statusText)
            try {
              const errorText = await response.text()
              // console.log('GeneManager: Parsing error response (first 500 chars):', errorText.substring(0, 500))
            } catch (textError) {
              console.error('GeneManager: Could not read error response text:', textError)
            }
          }
        } catch (e) {
          console.error('GeneManager: Exception loading parsing autocomplete file:', e)
          console.error('GeneManager: Exception name:', e.name)
          console.error('GeneManager: Exception message:', e.message)
          console.error('GeneManager: Exception stack:', e.stack)
        }
      }

      if (data && data.search) {
        this.autocompleteData = data.search
        const geneCount = this.autocompleteData.length
        this.totalGeneCount = geneCount
        // console.log(`GeneManager: Successfully loaded ${geneCount} genes for autocomplete`)
        // console.log('GeneManager: First 3 entries:', this.autocompleteData.slice(0, 3))
        // Update the gene count badge
        this.updateGeneCountBadge()
      } else {
        console.warn('GeneManager: Failed to load autocomplete data - data:', data, 'has search:', !!data?.search)
        this.autocompleteData = []
        this.totalGeneCount = 0
        this.updateGeneCountBadge()
      }
      this.autocompleteLoaded = true
      this.updateGeneSearchVisibility()
    } catch (error) {
      console.error('GeneManager: Error loading autocomplete data:', error)
      console.error('GeneManager: Error stack:', error.stack)
      this.autocompleteData = []
      this.totalGeneCount = 0
      this.updateGeneCountBadge()
      this.autocompleteLoaded = true
      this.updateGeneSearchVisibility()
    }
  }

  handleInput(query) {
    // console.log('GeneManager: handleInput called with query:', query)
    if (!query || query.trim().length === 0) {
      // console.log('GeneManager: Empty query, hiding dropdown')
      this.hideDropdown()
      return
    }

    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      console.warn('GeneManager: No autocomplete data available, length:', this.autocompleteData?.length)
      return
    }

    // console.log('GeneManager: Searching in', this.autocompleteData.length, 'entries')
    const searchTerm = query.toLowerCase().trim()
    this.currentMatches = this.autocompleteData
      .filter(entry => {
        // Parse entry: "gene_symbol FBgn0000000 {stable_id}"
        const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
        if (!match) {
          console.warn('GeneManager: Entry does not match pattern:', entry.substring(0, 50))
          return false
        }
        
        const [, geneSymbol, ensemblId, stableId] = match
        const searchLower = searchTerm.toLowerCase()
        
        const matches = geneSymbol.toLowerCase().includes(searchLower) ||
               ensemblId.toLowerCase().includes(searchLower) ||
               stableId.includes(searchTerm)
        
        return matches
      })
      .slice(0, 10) // Limit to 10 results

    // console.log('GeneManager: Found', this.currentMatches.length, 'matches for query:', searchTerm)
    if (this.currentMatches.length > 0) {
      // console.log('GeneManager: First match:', this.currentMatches[0])
      this.renderDropdown()
      this.showDropdown()
    } else {
      // console.log('GeneManager: No matches found, hiding dropdown')
      this.hideDropdown()
    }
  }

  renderDropdown() {
    // console.log('GeneManager: renderDropdown called with', this.currentMatches.length, 'matches')
    const dropdown = document.getElementById('gene-autocomplete-dropdown')
    if (!dropdown) {
      console.error('GeneManager: Dropdown element not found! ID: gene-autocomplete-dropdown')
      return
    }

    dropdown.innerHTML = ''

    this.currentMatches.forEach((entry, index) => {
      const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
      if (!match) return

      const [, geneSymbol, ensemblId, stableId] = match
      const item = document.createElement('div')
      item.style.cssText = 'padding: 10px 12px; cursor: pointer; border-bottom: 1px solid #f3f4f6; transition: background-color 0.15s;'
      item.innerHTML = `
        <div style="font-weight: 500; color: #111827; font-size: 14px;">${geneSymbol}</div>
        <div style="font-size: 12px; color: #6b7280; margin-top: 2px;">${ensemblId} | Stable ID: ${stableId}</div>
      `
      
      item.addEventListener('mouseenter', () => {
        item.style.backgroundColor = '#f3f4f6'
      })
      item.addEventListener('mouseleave', () => {
        item.style.backgroundColor = 'white'
      })

      item.addEventListener('click', () => {
        this.selectGene(entry)
      })

      dropdown.appendChild(item)
    })

    if (this.currentMatches.length === 0) {
      const noResults = document.createElement('div')
      noResults.style.cssText = 'padding: 10px 12px; color: #6b7280; font-size: 14px;'
      noResults.textContent = 'No genes found'
      dropdown.appendChild(noResults)
    }
  }

  showDropdown() {
    const dropdown = document.getElementById('gene-autocomplete-dropdown')
    if (dropdown) {
      dropdown.style.display = 'block'
      // console.log('GeneManager: Dropdown shown')
    } else {
      console.error('GeneManager: Cannot show dropdown - element not found')
    }
  }

  hideDropdown() {
    const dropdown = document.getElementById('gene-autocomplete-dropdown')
    if (dropdown) {
      dropdown.style.display = 'none'
      // console.log('GeneManager: Dropdown hidden')
    } else {
      console.error('GeneManager: Cannot hide dropdown - element not found')
    }
  }

  selectGene(entry) {
    // Parse the entry to extract gene information
    const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
    if (!match) {
      console.error('GeneManager: Invalid gene entry format:', entry)
      return
    }

    const [, geneSymbol, ensemblId, stableId] = match
    
    const gene = {
      symbol: geneSymbol,
      ensemblId: ensemblId,
      stableId: parseInt(stableId),
      query: geneSymbol
    }

    // Add to tags if not already present
    const existingIndex = this.geneTags.findIndex(g => g.stableId === gene.stableId)
    if (existingIndex === -1) {
      this.geneTags.push(gene)
      // Update badge when gene is added
      this.updateGeneCountBadge()
      // Only add the new gene instead of re-rendering all genes
      // This preserves the state of existing genes (filter icons, expansion, etc.)
      const resultsDiv = document.getElementById('gene-expression-results')
      if (resultsDiv) {
        this.displayBulkGene(gene, resultsDiv)
        this.loadGeneExpressionData(gene, resultsDiv)
      }
    }

    // Clear input
    const input = document.getElementById('gene-autocomplete-input')
    if (input) {
      input.value = ''
    }

    this.hideDropdown()
  }

  renderGeneTags() {
    // Don't render tags anymore - keep input field empty
    // Just ensure input is in the container and clear any existing tags
    const container = document.getElementById('gene-tags-container')
    const input = document.getElementById('gene-autocomplete-input')
    if (!container || !input) return

    // Clear any existing tags
    const existingTags = container.querySelectorAll('.gene-tag')
    existingTags.forEach(tag => tag.remove())

    // Ensure input is in the container
    if (input.parentElement !== container) {
      if (input.parentElement) {
        input.parentElement.removeChild(input)
      }
      container.appendChild(input)
    }

    this.syncMatrixSelectionFromUI()
  }

  syncMatrixSelectionFromUI() {
    let selectedLayer = null
    let selectedAnnotId = null

    const select = document.getElementById('gene-expression-matrix-select')
    if (select && select.options.length > 0) {
      const option = select.options[select.selectedIndex]
      selectedLayer = option?.value || '/matrix'
      const optionAnnotId = option?.dataset?.annotId
      selectedAnnotId = optionAnnotId && optionAnnotId !== '' ? String(optionAnnotId) : null
    } else {
      const link = document.getElementById('matrix-selection-link')
      if (link) {
        selectedLayer = link.dataset.layer || link.textContent?.trim() || '/matrix'
        const linkAnnot = link.dataset.annotId
        selectedAnnotId = linkAnnot && linkAnnot !== '' ? String(linkAnnot) : null
      }
    }

    if (selectedLayer) {
      if (this.currentMatrixLayer !== selectedLayer || this.currentMatrixAnnotId !== selectedAnnotId) {
        // console.log('GeneManager: syncMatrixSelectionFromUI detected mismatch', {
          // previousLayer: this.currentMatrixLayer,
          // previousAnnotId: this.currentMatrixAnnotId,
          // selectedLayer,
          // selectedAnnotId
        // })
      }
      this.currentMatrixLayer = selectedLayer
      this.currentMatrixAnnotId = selectedAnnotId
      this.matrixInitialized = true
    }
  }

  removeGeneTag(index) {
    if (index >= 0 && index < this.geneTags.length) {
      const geneToRemove = this.geneTags[index]
      const metadataKeys = geneToRemove ? this.getGeneMetadataKeys(String(geneToRemove.stableId), this.currentMatrixAnnotId) : null
      const metadataIds = metadataKeys ? [metadataKeys.baseKey, metadataKeys.layerKey] : []
      
      // Check if this gene is currently being used for coloring
      const isCurrentlyColoring = metadataIds.some(id => id && this.controller?.currentMetadataVector?.id === id)
      
      if (isCurrentlyColoring) {
        // console.log(`🧬 Removing gene ${geneToRemove.stableId} that is currently being used for coloring - clearing coloring`)
        // Clear the coloring since the gene is being removed
        this.controller.resetAllWaterDropButtons()
        this.controller.removeAllCategoryColors()
        this.controller.clearMetadataColoring()
      }
      
      // Clear cached data for this gene
      metadataIds.forEach(id => {
        if (!id) return
        if (this.controller?.loadedMetadataVectors && this.controller.loadedMetadataVectors[id]) {
          delete this.controller.loadedMetadataVectors[id]
        }
        if (this.controller?.inlineRangeSliderData && this.controller.inlineRangeSliderData[id]) {
          delete this.controller.inlineRangeSliderData[id]
        }
        if (this.controller?.selectedRanges && this.controller.selectedRanges[id]) {
          delete this.controller.selectedRanges[id]
        }
      })
      
      this.geneTags.splice(index, 1)
      // Update badge when gene is removed
      this.updateGeneCountBadge()
      // Don't render tags, just process
      this.processAllGenes()
    }
  }

  removeGeneByStableId(stableId) {
    const index = this.geneTags.findIndex(g => g.stableId === stableId)
    if (index !== -1) {
      const metadataKeys = this.getGeneMetadataKeys(stableId, this.currentMatrixAnnotId)
      const metadataIds = [metadataKeys.baseKey, metadataKeys.layerKey]
      
      // Check if this gene is currently being used for coloring
      const isCurrentlyColoring = metadataIds.some(id => id && this.controller?.currentMetadataVector?.id === id)
      
      if (isCurrentlyColoring) {
        // console.log(`🧬 Removing gene ${stableId} that is currently being used for coloring - clearing coloring`)
        // Clear the coloring since the gene is being removed
        this.controller.resetAllWaterDropButtons()
        this.controller.removeAllCategoryColors()
        this.controller.clearMetadataColoring()
      }
      
      metadataIds.forEach(id => {
        if (!id) return
        if (this.controller?.loadedMetadataVectors && this.controller.loadedMetadataVectors[id]) {
          delete this.controller.loadedMetadataVectors[id]
        }
        if (this.controller?.inlineRangeSliderData && this.controller.inlineRangeSliderData[id]) {
          delete this.controller.inlineRangeSliderData[id]
        }
        if (this.controller?.selectedRanges && this.controller.selectedRanges[id]) {
          delete this.controller.selectedRanges[id]
        }
      })
      
      this.geneTags.splice(index, 1)
      // Update badge when gene is removed
      this.updateGeneCountBadge()
      // Remove the gene div from the UI
      const geneDiv = document.getElementById(`gene-result-${stableId}`)
      if (geneDiv) {
        geneDiv.remove()
      }
      // If no genes left, clear the results
      if (this.geneTags.length === 0) {
        const resultsDiv = document.getElementById('gene-expression-results')
        if (resultsDiv) {
          resultsDiv.innerHTML = ''
        }
      }
    }
  }

  processGeneInput(query, trackNotFound = false) {
    if (!query || !query.trim()) return null

    // Wait for autocomplete data if needed
    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      // console.log('GeneManager: Waiting for autocomplete data...')
      setTimeout(() => {
        this.processGeneInput(query, trackNotFound)
      }, 500)
      return null
    }

    const matched = this.findGeneInAutocomplete(query.trim())
    if (matched) {
      // Check if already in tags
      const existingIndex = this.geneTags.findIndex(g => g.stableId === matched.stableId)
      if (existingIndex === -1) {
        this.geneTags.push(matched)
        // Update badge when gene is added
        this.updateGeneCountBadge()
        // Only add the new gene instead of re-rendering all genes
        // This preserves the state of existing genes (filter icons, expansion, etc.)
        const resultsDiv = document.getElementById('gene-expression-results')
        if (resultsDiv) {
          this.displayBulkGene(matched, resultsDiv)
          this.loadGeneExpressionData(matched, resultsDiv)
        }
        return { found: true, gene: matched }
      }
      return { found: true, gene: matched, duplicate: true }
    } else {
      // Gene not found
      if (trackNotFound && !this.notFoundQueries.includes(query.trim())) {
        this.notFoundQueries.push(query.trim())
      }
      // console.log('GeneManager: Gene not found:', query)
      return { found: false, query: query.trim() }
    }
  }

  processBulkGeneInput(genes) {
    if (!genes || genes.length === 0) return

    // Clear previous not found list
    this.notFoundQueries = []
    const foundCount = { count: 0, duplicates: 0 }
    const notFoundGenes = []

    // Process each gene
    for (const gene of genes) {
      const result = this.processGeneInput(gene, true)
      if (result) {
        if (result.found) {
          if (result.duplicate) {
            foundCount.duplicates++
          } else {
            foundCount.count++
          }
        } else {
          notFoundGenes.push(result.query)
        }
      }
    }

    // Update notFoundQueries
    this.notFoundQueries = notFoundGenes

    // Show status message
    this.showInputStatus(foundCount.count, notFoundGenes.length, foundCount.duplicates)

    // Trigger processing of all genes
    this.processAllGenes()
  }

  showInputStatus(foundCount, notFoundCount, duplicateCount = 0) {
    const statusDiv = document.getElementById('gene-input-status')
    const statusTextDiv = document.getElementById('gene-input-status-text')
    if (!statusDiv || !statusTextDiv) return

    delete statusDiv.dataset.statusLocked
    if (foundCount === 0 && notFoundCount === 0) {
      if (statusDiv.dataset.statusType === 'summary') {
        delete statusDiv.dataset.statusType
        statusDiv.style.display = 'none'
        statusTextDiv.innerHTML = ''
      }
      return
    }

    statusDiv.dataset.statusType = 'summary'
    statusDiv.style.display = 'block'
    
    let message = ''
    if (foundCount > 0) {
      message += `<span style="color: #059669; font-weight: 500;">Found: ${foundCount}</span>`
      if (duplicateCount > 0) {
        message += ` <span style="color: #6b7280; font-size: 12px;">(${duplicateCount} duplicates skipped)</span>`
      }
    }
    
    if (notFoundCount > 0) {
      if (message) message += ' | '
      message += `<span style="color: #dc2626; font-weight: 500;">Not found: ${notFoundCount}</span>`
      const linkId = 'show-not-found-link-' + Date.now()
      message += ` <a href="#" id="${linkId}" style="color: #0369a1; text-decoration: underline; cursor: pointer; margin-left: 4px;">View list</a>`
      
      // Add click handler after DOM update
      setTimeout(() => {
        const link = document.getElementById(linkId)
        if (link) {
          link.addEventListener('click', (e) => {
            e.preventDefault()
            this.showNotFoundGenes()
          })
        }
      }, 0)
    }

    statusTextDiv.innerHTML = message
  }

  async processAllGenes() {
    // Check renderer state before processing genes (for debugging)
    // console.log('🧬 [GENE ADD] processAllGenes called, checking renderer state before DOM manipulation:')
    const beforeProcessState = {
      hasReglRenderer: !!this.controller.reglRenderer,
      rendererInstanceId: this.controller.reglRenderer?.instanceId || 'none',
      numPoints: this.controller.reglRenderer?.numPoints || 0,
      hasPositions: !!this.controller.reglRenderer?.positions,
      positionsLength: this.controller.reglRenderer?.positions?.length || 0,
      hasCurrentCoordinates: !!this.controller.currentCoordinates,
      currentCoordinatesLength: this.controller.currentCoordinates?.length || 0
    }
    // console.log('🧬 [GENE ADD] Before processAllGenes state:', beforeProcessState)
    
    // CRITICAL: Store renderer reference before DOM manipulation
    // The gene container is OUTSIDE the visualization controller, so DOM changes
    // shouldn't affect the controller, but we'll preserve the reference just in case
    const preservedRenderer = this.controller.reglRenderer
    const preservedRendererId = preservedRenderer?.instanceId
    
    if (this.geneTags.length === 0) {
      // Clear results if no genes
      const resultsDiv = document.getElementById('gene-expression-results')
      const summaryDiv = document.getElementById('gene-results-summary')
      if (resultsDiv) {
        // Use removeChild to avoid potential Stimulus reconnection issues
        while (resultsDiv.firstChild) {
          resultsDiv.removeChild(resultsDiv.firstChild)
        }
      }
      if (summaryDiv) summaryDiv.style.display = 'none'
      
      // Verify renderer is still intact after DOM manipulation
      if (this.controller.reglRenderer !== preservedRenderer) {
        console.error('❌ [GENE ADD] CRITICAL: Renderer reference changed when clearing empty genes!')
        console.error('❌ [GENE ADD] Before:', preservedRendererId, 'After:', this.controller.reglRenderer?.instanceId || 'none')
        // Restore the preserved renderer
        this.controller.reglRenderer = preservedRenderer
      }
      return
    }

    const summaryDiv = document.getElementById('gene-results-summary')
    const resultsDiv = document.getElementById('gene-expression-results')

    if (!resultsDiv) return

    // Hide summary - no longer showing "Found" notice
    if (summaryDiv) {
      summaryDiv.style.display = 'none'
    }

    // Clear and display results
    // Use removeChild instead of innerHTML to avoid potential Stimulus reconnection
    // The gene container is outside the visualization controller, but be safe
    while (resultsDiv.firstChild) {
      resultsDiv.removeChild(resultsDiv.firstChild)
    }
    resultsDiv.style.cssText = '' // Reset any inline styles
    
    // Verify renderer is still intact after DOM manipulation
    if (this.controller.reglRenderer !== preservedRenderer) {
      console.error('❌ [GENE ADD] CRITICAL: Renderer reference changed during DOM manipulation!')
      console.error('❌ [GENE ADD] Before:', preservedRendererId, 'After:', this.controller.reglRenderer?.instanceId || 'none')
      console.trace('❌ [GENE ADD] Stack trace for renderer reference change')
      // Restore the preserved renderer
      this.controller.reglRenderer = preservedRenderer
    }
    
    // Check renderer state after DOM manipulation (for debugging)
    // console.log('🧬 [GENE ADD] After innerHTML = "", checking renderer state:')
    const afterDOMState = {
      hasReglRenderer: !!this.controller.reglRenderer,
      rendererInstanceId: this.controller.reglRenderer?.instanceId || 'none',
      numPoints: this.controller.reglRenderer?.numPoints || 0,
      hasPositions: !!this.controller.reglRenderer?.positions,
      positionsLength: this.controller.reglRenderer?.positions?.length || 0,
      hasCurrentCoordinates: !!this.controller.currentCoordinates,
      currentCoordinatesLength: this.controller.currentCoordinates?.length || 0
    }
    // console.log('🧬 [GENE ADD] After DOM manipulation state:', afterDOMState)
    
    // Check if renderer changed during DOM manipulation
    if (beforeProcessState.rendererInstanceId !== afterDOMState.rendererInstanceId) {
      console.error('❌ [GENE ADD] CRITICAL: Renderer instance changed during DOM manipulation!')
      console.error('❌ [GENE ADD] Before:', beforeProcessState.rendererInstanceId, 'After:', afterDOMState.rendererInstanceId)
      console.trace('❌ [GENE ADD] Renderer instance change during processAllGenes')
    }

    // Display all genes and load their expression data
    for (const gene of this.geneTags) {
      this.displayBulkGene(gene, resultsDiv)
    }

    // Load expression data for all genes
    for (const gene of this.geneTags) {
      await this.loadGeneExpressionData(gene, resultsDiv)
    }
    
    // Restore filter state icons for all genes that have subranges selected
    // This is needed because displayBulkGene recreates the DOM, losing the icon state
    // We check selectedRanges to determine if a gene has a subrange, and restore the icon accordingly
    setTimeout(() => {
      for (const gene of this.geneTags) {
        const geneId = String(gene.stableId)
        const geneMetadataId = this.getGeneMetadataId(geneId, this.currentMatrixAnnotId)
        
        // Check if this gene has a subrange in selectedRanges
        const selectedRange = this.controller?.selectedRanges?.[geneMetadataId]
        const geneFilterStateIcon = document.querySelector(`.gene-filter-state-icon[data-gene-id="${geneId}"]`)
        
        if (geneFilterStateIcon) {
          if (selectedRange && selectedRange.min !== undefined && selectedRange.max !== undefined) {
            // Check if it's a subrange (not the full range)
            // We need to get the min/max values to compare
            const sliderData = this.controller?.inlineRangeSliderData?.[geneMetadataId]
            if (sliderData) {
              const minVal = sliderData.min
              const maxVal = sliderData.max
              const tolerance = (maxVal - minVal) * 0.001 // 0.1% tolerance
              const isFullRange = Math.abs(selectedRange.min - minVal) < tolerance && 
                                  Math.abs(selectedRange.max - maxVal) < tolerance
              
              // Show the icon
              geneFilterStateIcon.style.display = 'flex'
              const icon = geneFilterStateIcon.querySelector('i')
              
              if (isFullRange) {
                // Full range - white background, gray icon
                geneFilterStateIcon.style.backgroundColor = 'white'
                geneFilterStateIcon.style.borderColor = '#d1d5db'
                if (icon) {
                  icon.style.color = '#9ca3af'
                }
                geneFilterStateIcon.title = 'No filter applied (full range)'
              } else {
                // Subrange - orange background, white icon
                geneFilterStateIcon.style.backgroundColor = '#f59e0b'
                geneFilterStateIcon.style.borderColor = '#f59e0b'
                if (icon) {
                  icon.style.color = 'white'
                }
                geneFilterStateIcon.title = `Subrange selected: ${selectedRange.min.toFixed(3)} - ${selectedRange.max.toFixed(3)}`
              }
            } else {
              // Slider data not available yet, but we have a range - assume it's a subrange
              geneFilterStateIcon.style.display = 'flex'
              const icon = geneFilterStateIcon.querySelector('i')
              geneFilterStateIcon.style.backgroundColor = '#f59e0b'
              geneFilterStateIcon.style.borderColor = '#f59e0b'
              if (icon) {
                icon.style.color = 'white'
              }
              geneFilterStateIcon.title = `Subrange selected: ${selectedRange.min.toFixed(3)} - ${selectedRange.max.toFixed(3)}`
            }
          } else {
            // No subrange selected - show default state
            geneFilterStateIcon.style.display = 'flex'
            const icon = geneFilterStateIcon.querySelector('i')
            geneFilterStateIcon.style.backgroundColor = 'white'
            geneFilterStateIcon.style.borderColor = '#d1d5db'
            if (icon) {
              icon.style.color = '#9ca3af'
            }
            geneFilterStateIcon.title = 'No filter applied (full range)'
          }
        }
        
        // Also try to trigger updateCheckboxColor if the range slider controller is available
        const rangeSliderElement = document.querySelector(`[data-range-slider-metadata-id-value="${geneMetadataId}"]`)
        if (rangeSliderElement && this.controller) {
          const rangeSliderController = this.controller.application?.getControllerForElementAndIdentifier(
            rangeSliderElement,
            'range-slider'
          )
          
          if (rangeSliderController) {
            // Trigger updateCheckboxColor to ensure consistency
            rangeSliderController.updateCheckboxColor()
          }
        }
      }
    }, 100)
  }

  displayGeneInfo(gene) {
    const resultsDiv = document.getElementById('gene-expression-results')
    if (!resultsDiv) return

    // Build gene name display: symbol + Ensembl ID + (stable ID if admin)
    const stableIdDisplay = this.isAdmin ? ` (${gene.stableId})` : ''
    
    resultsDiv.innerHTML = `
      <div style="padding: 16px; background-color: #f9fafb; border-radius: 6px; border: 1px solid #e5e7eb;">
        <div style="margin-bottom: 12px;">
          <h3 style="margin: 0; font-size: 16px; font-weight: 600; color: #111827;">
            ${gene.symbol}
            <span style="font-size: 14px; font-weight: 400; color: #6b7280; margin-left: 8px; font-family: monospace;">${gene.ensemblId}</span>
            ${stableIdDisplay ? `<span style="font-size: 14px; font-weight: 400; color: #9ca3af; margin-left: 4px;">${stableIdDisplay}</span>` : ''}
          </h3>
        </div>
        <div id="gene-expression-loading" style="color: #6b7280; font-size: 14px;">Loading expression data...</div>
        <div id="gene-expression-data" style="display: none;"></div>
      </div>
    `
  }

  async findGeneIndexesByStableId(stableId) {
    const loadingDiv = document.getElementById('gene-expression-loading')
    const dataDiv = document.getElementById('gene-expression-data')
    
    if (!loadingDiv || !dataDiv) return

    try {
      // Get current loom file from controller
      let loomFile = 'parsing/output.loom'
      try {
        if (this.controller.getCurrentLoomFileForRequest) {
          loomFile = this.controller.getCurrentLoomFileForRequest()
        }
      } catch (e) {
        console.warn('GeneManager: Could not get current loom file, using default:', e.message)
      }

      // Build URL with matrix/layer parameter if not default
      let url = `/projects/${encodeURIComponent(this.projectIdentifier)}/gene_expression.json?stable_id=${encodeURIComponent(stableId)}&loom_file=${encodeURIComponent(loomFile)}`
      if (this.currentMatrixAnnotId) {
        url += `&annot_id=${encodeURIComponent(this.currentMatrixAnnotId)}`
      } else if (this.currentMatrixLayer && this.currentMatrixLayer !== '/matrix') {
        url += `&layer=${encodeURIComponent(this.currentMatrixLayer)}`
      }
      
      const response = await fetch(url)
      if (!response.ok) {
        const errorData = await response.json().catch(() => ({ error: 'Unknown error' }))
        throw new Error(errorData.error || `HTTP ${response.status}`)
      }

      const data = await response.json()
      
      if (data.error) {
        throw new Error(data.error)
      }

      // Display the expression data
      loadingDiv.style.display = 'none'
      dataDiv.style.display = 'block'
      
      const expressionValues = data.expression_values || []
      const stats = this.calculateExpressionStats(expressionValues)

      dataDiv.innerHTML = `
        <div style="padding: 12px; background-color: white; border-radius: 4px; border: 1px solid #e5e7eb;">
          <div style="margin-bottom: 12px;">
            <div style="font-size: 13px; font-weight: 500; color: #374151; margin-bottom: 8px;">Expression Statistics</div>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 12px;">
              <div>
                <span style="color: #6b7280;">Cells:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.nCells.toLocaleString()}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Mean:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.mean.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Min:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.min.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Max:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.max.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Median:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.median.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Std Dev:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.stdDev.toFixed(2)}</span>
              </div>
            </div>
          </div>
          <div style="font-size: 11px; color: #6b7280; margin-top: 8px; padding-top: 8px; border-top: 1px solid #e5e7eb;">
            Gene Index: ${data.gene_index} | Stable ID: ${data.stable_id}
          </div>
        </div>
      `
    } catch (error) {
      console.error('GeneManager: Error loading gene expression:', error)
      loadingDiv.style.display = 'none'
      dataDiv.style.display = 'block'
      dataDiv.innerHTML = `
        <div style="padding: 12px; background-color: #fef2f2; border-radius: 4px; border: 1px solid #fecaca; color: #dc2626; font-size: 14px;">
          Error loading expression data: ${error.message}
        </div>
      `
    }
  }

  calculateExpressionStats(values) {
    if (!values || values.length === 0) {
      return {
        nCells: 0,
        mean: 0,
        min: 0,
        max: 0,
        median: 0,
        stdDev: 0
      }
    }

    const numericValues = values.map(v => parseFloat(v)).filter(v => !isNaN(v))
    
    if (numericValues.length === 0) {
      return {
        nCells: values.length,
        mean: 0,
        min: 0,
        max: 0,
        median: 0,
        stdDev: 0
      }
    }

    const sorted = [...numericValues].sort((a, b) => a - b)
    const sum = numericValues.reduce((a, b) => a + b, 0)
    const mean = sum / numericValues.length
    const variance = numericValues.reduce((sum, val) => sum + Math.pow(val - mean, 2), 0) / numericValues.length
    const stdDev = Math.sqrt(variance)
    
    const median = sorted.length % 2 === 0
      ? (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2
      : sorted[Math.floor(sorted.length / 2)]

    return {
      nCells: numericValues.length,
      mean: mean,
      min: sorted[0],
      max: sorted[sorted.length - 1],
      median: median,
      stdDev: stdDev
    }
  }

  parseBulkGeneInput(inputText) {
    // Split by newlines, commas, spaces, or tabs
    const genes = inputText
      .split(/[\n,\s\t]+/)
      .map(g => g.trim())
      .filter(g => g.length > 0)
    
    // Remove duplicates while preserving order
    return [...new Set(genes)]
  }

  findGeneInAutocomplete(query) {
    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      return null
    }

    const searchTerm = query.trim().toLowerCase()
    
    // Try to find exact or partial match
    for (const entry of this.autocompleteData) {
      const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
      if (!match) continue
      
      const [, geneSymbol, ensemblId, stableId] = match
      
      // Check for exact match on symbol, Ensembl ID, or stable ID
      if (geneSymbol.toLowerCase() === searchTerm ||
          ensemblId.toLowerCase() === searchTerm ||
          stableId === searchTerm ||
          geneSymbol.toLowerCase().startsWith(searchTerm) ||
          ensemblId.toLowerCase().startsWith(searchTerm)) {
        return {
          symbol: geneSymbol,
          ensemblId: ensemblId,
          stableId: parseInt(stableId),
          originalQuery: query
        }
      }
    }
    
    return null
  }

  async processBulkGenes() {
    const bulkInput = document.getElementById('bulk-gene-input')
    const summaryDiv = document.getElementById('bulk-gene-summary')
    const statsDiv = document.getElementById('bulk-gene-stats')
    const notFoundLinkDiv = document.getElementById('bulk-gene-not-found-link')
    const resultsDiv = document.getElementById('gene-expression-results')
    
    if (!bulkInput || !summaryDiv || !statsDiv || !resultsDiv) {
      console.error('GeneManager: Required elements not found for bulk processing')
      return
    }

    const inputText = bulkInput.value.trim()
    if (!inputText) {
      alert('Please enter at least one gene symbol or Ensembl ID')
      return
    }

    // Wait for autocomplete data if not loaded yet
    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      // console.log('GeneManager: Autocomplete data not loaded, waiting...')
      await this.loadAutocompleteData()
      
      // Try again after a short delay
      await new Promise(resolve => setTimeout(resolve, 500))
    }

    const geneQueries = this.parseBulkGeneInput(inputText)
    // console.log('GeneManager: Processing', geneQueries.length, 'genes:', geneQueries)

    // Match genes
    this.processedGenes = []
    this.notFoundGenes = []
    
    for (const query of geneQueries) {
      const matched = this.findGeneInAutocomplete(query)
      if (matched) {
        this.processedGenes.push(matched)
      } else {
        this.notFoundGenes.push(query)
      }
    }

    // Display summary
    const foundCount = this.processedGenes.length
    const notFoundCount = this.notFoundGenes.length
    const totalCount = geneQueries.length

    statsDiv.innerHTML = `
      <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
        <span style="color: #059669; font-weight: 500;">✓ Found: ${foundCount}</span>
        <span style="color: #dc2626; font-weight: 500;">✗ Not Found: ${notFoundCount}</span>
        <span style="color: #6b7280;">Total: ${totalCount}</span>
      </div>
    `

    // Show link to view not found genes if any
    if (notFoundCount > 0) {
      const linkId = `show-not-found-${Date.now()}`
      notFoundLinkDiv.style.display = 'block'
      notFoundLinkDiv.innerHTML = `
        <a href="#" id="${linkId}" style="color: #3b82f6; text-decoration: none; font-size: 13px; font-weight: 500;">
          View ${notFoundCount} not found ${notFoundCount === 1 ? 'gene' : 'genes'} →
        </a>
      `
      
      // Add click handler
      setTimeout(() => {
        const link = document.getElementById(linkId)
        if (link) {
          link.addEventListener('click', (e) => {
            e.preventDefault()
            this.showNotFoundGenes()
          })
        }
      }, 100)
    } else {
      notFoundLinkDiv.style.display = 'none'
    }

    summaryDiv.style.display = 'block'

    // Clear and display results for found genes
    resultsDiv.innerHTML = ''
    
    if (foundCount > 0) {
      // Display all found genes
      for (const gene of this.processedGenes) {
        this.displayBulkGene(gene, resultsDiv)
      }
      
      // Load expression data for all found genes
      for (const gene of this.processedGenes) {
        await this.loadGeneExpressionData(gene, resultsDiv)
      }
    } else {
      resultsDiv.innerHTML = `
        <div style="padding: 16px; background-color: #fef2f2; border-radius: 6px; border: 1px solid #fecaca; color: #dc2626; font-size: 14px; text-align: center;">
          No genes were found. Please check your input and try again.
        </div>
      `
    }

    // Scroll to results
    resultsDiv.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  displayBulkGene(gene, container) {
    this.syncMatrixSelectionFromUI()
    const geneDiv = document.createElement('div')
    geneDiv.id = `gene-result-${gene.stableId}`
    geneDiv.setAttribute('data-gene-item', gene.stableId)
    geneDiv.style.cssText = 'border: 1px solid #e5e7eb; border-radius: 8px; margin-bottom: 8px;'
    
    // Build gene name display: symbol + Ensembl ID + (stable ID if admin)
    const stableIdDisplay = this.isAdmin ? ` (${gene.stableId})` : ''
    const geneIdStr = String(gene.stableId)
    const { baseKey: baseMetadataId, layerKey: layerMetadataId } = this.getGeneMetadataKeys(geneIdStr, this.currentMatrixAnnotId)
    const geneIdNum = parseInt(geneIdStr)
    
    geneDiv.innerHTML = `
      <div style="display: flex; align-items: center; padding: 8px; cursor: pointer; transition: background-color 0.2s;" 
           class="gene-header"
           data-gene-id="${gene.stableId}"
           onmouseover="this.style.backgroundColor='#f9fafb'" 
           onmouseout="this.style.backgroundColor=''">
        <!-- Chevron -->
        <div class="gene-chevron" style="margin-right: 12px; color: #9ca3af;">
          <i class="fas fa-chevron-right" style="font-size: 14px; transition: transform 0.3s ease-out;"></i>
        </div>
        <!-- Status Icon (shows data loading status) -->
        <div class="gene-status-icon" 
             data-gene-id="${gene.stableId}"
             title="Loading..."
             style="margin-right: 8px; display: flex; align-items: center; justify-content: center; width: 18px; height: 18px; border-radius: 50%; background-color: #9ca3af; transition: all 0.2s;">
          <i class="fas fa-spinner fa-spin" style="color: white; font-size: 10px;"></i>
        </div>
        <!-- Filter State Icon (shows if a subrange is selected) -->
        <div class="gene-filter-state-icon" 
             data-gene-id="${gene.stableId}"
             title="No filter applied (full range)"
             style="margin-right: 8px; display: flex; align-items: center; justify-content: center; width: 20px; height: 20px; background-color: white; border: 2px solid #d1d5db; border-radius: 4px; transition: all 0.2s;">
          <i class="fas fa-sliders" style="font-size: 12px; color: #9ca3af;"></i>
        </div>
        <!-- Content -->
        <div style="flex: 1; min-width: 0; margin-right: 8px;">
          <div style="font-size: 14px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;" title="${gene.symbol} ${gene.ensemblId}${stableIdDisplay}">
            ${gene.symbol}
            <span style="font-size: 13px; font-weight: 400; color: #6b7280; margin-left: 8px; font-family: monospace;">${gene.ensemblId}</span>
            ${stableIdDisplay ? `<span style="font-size: 13px; font-weight: 400; color: #9ca3af; margin-left: 4px;">${stableIdDisplay}</span>` : ''}
          </div>
        </div>
        <!-- ON/OFF Filter Switch (hidden by default, shown when gene is unfolded and has a range) -->
        <div class="gene-filter-switch" 
             data-gene-id="${gene.stableId}"
             data-filter-enabled="true"
             title="Enable/Disable filtering"
             style="margin-right: 8px; display: none; align-items: center; width: 32px; height: 18px; background-color: #10b981; border-radius: 9px; cursor: pointer; position: relative; transition: background-color 0.2s;"
             onclick="event.stopPropagation()">
          <div style="position: absolute; top: 2px; left: 2px; width: 14px; height: 14px; background-color: white; border-radius: 50%; transition: transform 0.2s; transform: translateX(14px);"></div>
        </div>
        <!-- Hidden Radio -->
        <input type="radio" name="color_by_gene" value="${gene.stableId}" style="display: none;">
        
        <!-- Download Button -->
        <button class="gene-download-btn"
                data-action="click->visualization#downloadGeneExpression"
                data-gene-id="${gene.stableId}"
                data-metadata-id="${baseMetadataId}"
                data-layer-metadata-id="${layerMetadataId}"
                style="padding: 4px; color: #9ca3af; background: none; border: none; border-radius: 4px; cursor: pointer; transition: all 0.2s; margin-right: 4px;"
                onmouseover="this.style.color='#6b7280'; this.style.backgroundColor='#f3f4f6';"
                onmouseout="this.style.color='#9ca3af'; this.style.backgroundColor='';"
                title="Download expression distribution"
                onclick="event.stopPropagation()">
          <i class="fas fa-file-download" style="font-size: 14px;"></i>
        </button>
        
        <!-- Button Group: X, Y buttons and Coloring -->
        <div style="display: flex; flex-direction: row; gap: 4px; align-items: center; margin-right: 4px;">
          <!-- X Button -->
          <button class="gene-x-btn"
                  data-gene-id="${gene.stableId}"
                  data-action="click->visualization#xButtonClicked"
                  data-active="false"
                  data-layer-metadata-id="${layerMetadataId}"
                  style="padding: 4px; color: #9ca3af; background: none; border: none; border-radius: 4px; cursor: pointer; transition: all 0.2s; font-size: 14px; font-style: italic; font-family: 'Times New Roman', serif;"
                  onmouseover="if(this.dataset.active !== 'true') { this.style.color='#6b7280'; this.style.backgroundColor='#f3f4f6'; }"
                  onmouseout="if(this.dataset.active !== 'true') { this.style.color='#9ca3af'; this.style.backgroundColor=''; }"
                  title="X axis"
                  onclick="event.stopPropagation()">
            x
          </button>
          <!-- Y Button -->
          <button class="gene-y-btn"
                  data-gene-id="${gene.stableId}"
                  data-action="click->visualization#yButtonClicked"
                  data-active="false"
                  data-layer-metadata-id="${layerMetadataId}"
                  style="padding: 4px; color: #9ca3af; background: none; border: none; border-radius: 4px; cursor: pointer; transition: all 0.2s; font-size: 14px; font-style: italic; font-family: 'Times New Roman', serif;"
                  onmouseover="if(this.dataset.active !== 'true') { this.style.color='#6b7280'; this.style.backgroundColor='#f3f4f6'; }"
                  onmouseout="if(this.dataset.active !== 'true') { this.style.color='#9ca3af'; this.style.backgroundColor=''; }"
                  title="Y axis"
                  onclick="event.stopPropagation()">
            y
          </button>
          <!-- Water Drop Button (Coloring) -->
          <button class="gene-color-btn"
                  data-action="click->visualization#geneWaterDropClicked"
                  data-gene-id="${gene.stableId}"
                  data-gene-name="${gene.symbol}"
                  data-metadata-id="${baseMetadataId}"
                  data-layer-metadata-id="${layerMetadataId}"
                  data-metadata-name="${gene.symbol}"
                  data-metadata-type="NUMERIC"
                  data-active="false"
                  style="padding: 4px; color: #9ca3af; background: none; border: none; border-radius: 4px; cursor: pointer; transition: all 0.2s;"
                  onmouseover="if(this.dataset.active !== 'true') { this.style.color='#6b7280'; this.style.backgroundColor='#f3f4f6'; }" 
                  onmouseout="if(this.dataset.active !== 'true') { this.style.color='#9ca3af'; this.style.backgroundColor=''; }"
                  title="Color by expression"
                  onclick="event.stopPropagation()">
            <i class="fas fa-palette" style="font-size: 16px;"></i>
          </button>
        </div>
        
        <!-- Remove Button -->
        <button 
          id="remove-gene-${gene.stableId}" 
          style="background: none; border: none; color: #6b7280; cursor: pointer; padding: 4px; font-size: 18px; line-height: 1; width: 24px; height: 24px; display: flex; align-items: center; justify-content: center; border-radius: 4px; transition: background-color 0.2s, color 0.2s; flex-shrink: 0;"
          onmouseover="this.style.backgroundColor='#fee2e2'; this.style.color='#dc2626'"
          onmouseout="this.style.backgroundColor=''; this.style.color='#6b7280'"
          title="Remove gene"
          onclick="event.stopPropagation()">
          ×
        </button>
      </div>
      <!-- Range Slider Section (initially hidden) -->
      <div class="gene-range-section" 
           data-gene-id="${gene.stableId}"
           style="padding: 12px; border-top: 1px solid #f3f4f6; display: none; background-color: #fafafa;">
        <!-- Range Slider -->
        <div data-controller="range-slider" 
             data-range-slider-metadata-id-value="${layerMetadataId}"
             data-layer-metadata-id-value="${layerMetadataId}"
             data-range-slider-min-value="0"
             data-range-slider-max-value="1"
             data-range-slider-current-min-value="0"
             data-range-slider-current-max-value="1"
             style="margin-bottom: 12px;">
          
          <!-- Min Value, Slider, Max Value, and Palette Button on Same Line -->
          <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 8px;">
            <!-- Min Value -->
            <input data-range-slider-target="minInput" type="number" class="range-min-input" 
                   style="width: 60px; padding: 4px 6px; border: 1px solid #d1d5db; border-radius: 4px; font-size: 11px; text-align: center;"
                   data-action="change->range-slider#minInputChanged">
            
            <!-- Slider -->
            <div style="flex: 1; position: relative; height: 20px;">
              <div data-range-slider-target="track" class="range-slider-track" style="position: absolute; top: 50%; left: 0; right: 0; height: 4px; background-color: #e5e7eb; border-radius: 2px; transform: translateY(-50%);"></div>
              <div data-range-slider-target="activeTrack" class="range-slider-active" style="position: absolute; top: 50%; height: 4px; background-color: #3b82f6; border-radius: 2px; transform: translateY(-50%);"></div>
              <div data-range-slider-target="minHandle" class="range-slider-min-handle" style="position: absolute; top: 50%; width: 16px; height: 16px; background-color: #3b82f6; border: 2px solid white; border-radius: 50%; transform: translate(-50%, -50%); cursor: grab; box-shadow: 0 2px 4px rgba(0,0,0,0.2);" 
                   data-action="mousedown->range-slider#startDrag touchstart->range-slider#startDrag"
                   data-range-slider-handle-param="min"></div>
              <div data-range-slider-target="maxHandle" class="range-slider-max-handle" style="position: absolute; top: 50%; width: 16px; height: 16px; background-color: #3b82f6; border: 2px solid white; border-radius: 50%; transform: translate(-50%, -50%); cursor: grab; box-shadow: 0 2px 4px rgba(0,0,0,0.2);" 
                   data-action="mousedown->range-slider#startDrag touchstart->range-slider#startDrag"
                   data-range-slider-handle-param="max"></div>
            </div>
            
            <!-- Max Value -->
            <input data-range-slider-target="maxInput" type="number" class="range-max-input" 
                   style="width: 60px; padding: 4px 6px; border: 1px solid #d1d5db; border-radius: 4px; font-size: 11px; text-align: center;"
                   data-action="change->range-slider#maxInputChanged">
            
            <!-- Color Range Adaptation Button -->
            <button data-range-slider-target="adaptColorRangeButton"
                    data-action="click->range-slider#adaptColorRangeChanged"
                    style="padding: 6px; border: 1px solid #d1d5db; border-radius: 4px; background-color: #f9fafb; color: #6b7280; cursor: pointer; transition: all 0.2s; display: flex; align-items: center; justify-content: center;"
                    title="Adapt color range to selected range - When enabled, the color legend will adjust to show the full range of selected values"
                    onmouseover="this.style.backgroundColor='#f3f4f6'; this.style.borderColor='#9ca3af';"
                    onmouseout="this.style.backgroundColor='#f9fafb'; this.style.borderColor='#d1d5db';">
              <i class="fas fa-palette" style="font-size: 14px;"></i>
            </button>
          </div>
          
          <!-- Selected Cells Count -->
          <div style="text-align: center; margin-bottom: 8px; font-size: 12px; color: #6b7280;">
            <span class="selected-cells-count" style="font-weight: 500;">
              Selected: <span data-range-slider-target="selectedCount" class="selected-count-number">0</span> cells
            </span>
          </div>
          
          <!-- Histogram with Highlighted Range -->
          <div style="margin-bottom: 8px;">
            <canvas data-range-slider-target="canvas" class="density-plot-canvas" data-gene-id="${gene.stableId}" 
                    style="width: 100%; height: 80px; border: 1px solid #e5e7eb; border-radius: 4px; background-color: white;"></canvas>
          </div>
        </div>
      </div>
      <!-- Loading indicator (shown while expression data loads) -->
      <div id="gene-expression-loading-${gene.stableId}" style="display: none; padding: 12px; color: #6b7280; font-size: 14px; text-align: center;">
        Loading expression data...
      </div>
    `
    container.appendChild(geneDiv)
    
    // Add click handler for header to toggle expansion
    const headerElement = geneDiv.querySelector('.gene-header')
    if (headerElement) {
      headerElement.addEventListener('click', (e) => {
        // Don't toggle if clicking on buttons
        if (e.target.closest('button') || e.target.closest('.gene-filter-switch')) {
          return
        }
        this.toggleGeneExpansion(gene.stableId)
      })
    }
    
    // Add click handler for remove button
    const removeBtn = document.getElementById(`remove-gene-${gene.stableId}`)
    if (removeBtn) {
      removeBtn.addEventListener('click', (e) => {
        e.stopPropagation()
        e.preventDefault()
        this.removeGeneByStableId(gene.stableId)
      })
    }
    
    // Setup button handlers
    this.setupGeneButtonHandlers(gene.stableId)
    
    // Check gene status and update icon
    this.checkGeneStatus(gene.stableId)
    
    // Load expression data immediately
    this.loadGeneExpressionData(gene, container)
    
    // Ensure slider data is initialized when gene expression data is loaded
    // This will be called again when data loads, but also try to initialize if data is already available
    const existingData = this.geneExpressionData[geneIdStr] || 
                         this.geneExpressionData[geneIdNum] || 
                         this.geneExpressionData[String(geneIdNum)]
    if (existingData && existingData.values && this.controller) {
      // Data already available, initialize slider data
      if (this.controller.initializeInlineRangeSlider) {
        this.controller.initializeInlineRangeSlider(layerMetadataId, existingData.values)
      }
    }
  }

  // Check gene expression status (in memory, in DB, or not loaded)
  async checkGeneStatus(geneId) {
    const geneIdStr = String(geneId)
    const geneIdNum = parseInt(geneId)
    const { baseKey: baseMetadataId, layerKey: layerMetadataId } = this.getGeneMetadataKeys(geneIdStr, this.currentMatrixAnnotId)
    
    // Check if in memory
    const inMemory = this.geneExpressionData[geneIdStr] || 
                     this.geneExpressionData[geneIdNum] || 
                     this.geneExpressionData[String(geneIdNum)]
    
    if (inMemory && inMemory.values && inMemory.values.length > 0) {
      if (this.controller && this.controller.uiManager) {
        this.controller.uiManager.updateGeneStatusIcon(geneIdStr, 'in-memory')
      }
      return 'in-memory'
    }
    
    // Check if in database
    if (this.controller && this.controller.memoryManager) {
      const inDatabase = await this.controller.memoryManager.checkGeneExpressionInDatabase(geneIdStr, {
        metadataKey: layerMetadataId,
        baseKey: baseMetadataId,
        expectedAnnotId: this.currentMatrixAnnotId
      })
      if (inDatabase) {
        if (this.controller && this.controller.uiManager) {
          this.controller.uiManager.updateGeneStatusIcon(geneIdStr, 'in-db')
        }
        return 'in-db'
      }
    }
    
    // Not loaded
    if (this.controller && this.controller.uiManager) {
      this.controller.uiManager.updateGeneStatusIcon(geneIdStr, 'not-loaded')
    }
    return 'not-loaded'
  }

  async loadGeneExpressionData(gene, container) {
    this.syncMatrixSelectionFromUI()
    const geneId = String(gene.stableId)
    const { baseKey: baseMetadataId, layerKey: geneMetadataId } = this.getGeneMetadataKeys(geneId, this.currentMatrixAnnotId)
    const statusIcon = document.querySelector(`.gene-status-icon[data-gene-id="${geneId}"]`)
    const loadingDiv = document.getElementById(`gene-expression-loading-${gene.stableId}`)
    
    // console.log('GeneManager: load request', {
      // geneId,
      // baseMetadataId,
      // layerMetadataId: geneMetadataId,
      // layer: this.currentMatrixLayer,
      // annotId: this.currentMatrixAnnotId
    // })

    // Check if already in memory
    const geneIdNum = parseInt(geneId)
    const inMemory = this.geneExpressionData[geneId] || 
                     this.geneExpressionData[geneIdNum] || 
                     this.geneExpressionData[String(geneIdNum)]
    
    if (inMemory && inMemory.values && inMemory.values.length > 0) {
      // Already in memory - update status icon
      if (statusIcon) {
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'in-memory')
      }
      if (loadingDiv) {
        loadingDiv.style.display = 'none'
      }
      // console.log('GeneManager: using cached expression data', { geneId, values: inMemory.values.length })
      return
    }
    
    // Check IndexedDB first (disk storage)
    if (this.controller && this.controller.memoryManager) {
      // Check if in database first
    const inDatabase = await this.controller.memoryManager.checkGeneExpressionInDatabase(geneId, {
      metadataKey: geneMetadataId,
      baseKey: baseMetadataId
    })
      if (inDatabase) {
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'in-db')
      } else {
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'not-loaded')
      }
      
      const dbData = await this.controller.memoryManager.loadGeneExpressionFromIndexedDB(geneId, {
        metadataKey: geneMetadataId,
        baseKey: baseMetadataId,
        expectedAnnotId: this.currentMatrixAnnotId
      })
      if (dbData && dbData.values && dbData.values.length > 0) {
        // Found in database - load into memory
        const stableIdKey = String(gene.stableId)
      const expressionData = {
          values: dbData.values,
          stats: dbData.stats || this.calculateExpressionStats(dbData.values),
          geneIndex: dbData.geneIndex,
          stableId: dbData.stableId || gene.stableId,
        symbol: dbData.symbol || gene.symbol,
        annotId: dbData.annotId ?? this.currentMatrixAnnotId,
        metadataId: dbData.metadataId || geneMetadataId,
        baseMetadataId: dbData.baseMetadataId || baseMetadataId
        }
        
        this.geneExpressionData[stableIdKey] = expressionData
        
        // Also store with numeric key for compatibility
        if (!isNaN(gene.stableId)) {
          this.geneExpressionData[gene.stableId] = expressionData
        }
        
        // Store in loadedMetadataVectors so filtering system can find it
        if (!this.controller.loadedMetadataVectors) {
          this.controller.loadedMetadataVectors = {}
        }
        const minVal = this.controller.dataManager.safeMin(expressionData.values)
        const maxVal = this.controller.dataManager.safeMax(expressionData.values)
        const restoredVector = {
          id: geneMetadataId,
          name: gene.symbol,
          display_name: gene.symbol,
          data_type: 'NUMERIC',
          values: expressionData.values,
          compression_info: {
            min_val: minVal,
            max_val: maxVal,
            data_type: 'NUMERIC'
          }
        }
        this.controller.loadedMetadataVectors[geneMetadataId] = restoredVector
        if (baseMetadataId !== geneMetadataId) {
          this.controller.loadedMetadataVectors[baseMetadataId] = restoredVector
        }
        
        // Initialize slider data immediately (needed for count updates)
        if (this.controller && this.controller.initializeInlineRangeSlider) {
          this.controller.initializeInlineRangeSlider(geneMetadataId, expressionData.values)
          if (baseMetadataId !== geneMetadataId && this.controller.inlineRangeSliderData) {
            this.controller.inlineRangeSliderData[baseMetadataId] = this.controller.inlineRangeSliderData[geneMetadataId]
          }
        }
        // console.log('GeneManager: restored from IndexedDB', { geneId, metadataId: geneMetadataId })
        
        // Update status icon to in-memory (loaded from DB into memory)
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'in-memory')
        if (loadingDiv) {
          loadingDiv.style.display = 'none'
        }
        
        // If gene is expanded, initialize range slider UI
        const geneDiv = document.querySelector(`[data-gene-item="${gene.stableId}"]`)
        if (geneDiv) {
          const rangeSection = geneDiv.querySelector('.gene-range-section')
          if (rangeSection && rangeSection.style.display !== 'none') {
            this.initializeGeneRangeSlider(gene.stableId)
          }
        }
        return
      } else {
        // Not in database - update status to downloading
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'downloading')
      }
    } else if (statusIcon) {
      statusIcon.style.display = 'flex'
      statusIcon.style.backgroundColor = '#9ca3af'
      statusIcon.title = 'Loading...'
    }
    
    if (loadingDiv) {
      loadingDiv.style.display = 'block'
    }

    try {
      let loomFile = 'parsing/output.loom'
      try {
        if (this.controller.getCurrentLoomFileForRequest) {
          loomFile = this.controller.getCurrentLoomFileForRequest()
        }
      } catch (e) {
        console.warn('GeneManager: Could not get current loom file, using default:', e.message)
      }

      // Build URL with matrix/layer parameter if not default
      let url = `/projects/${encodeURIComponent(this.projectIdentifier)}/gene_expression.json?stable_id=${encodeURIComponent(gene.stableId)}&loom_file=${encodeURIComponent(loomFile)}`
      if (this.currentMatrixAnnotId) {
        url += `&annot_id=${encodeURIComponent(this.currentMatrixAnnotId)}`
      } else if (this.currentMatrixLayer && this.currentMatrixLayer !== '/matrix') {
        url += `&layer=${encodeURIComponent(this.currentMatrixLayer)}`
      }
      
      // console.log('GeneManager: fetching expression data', { geneId, layer: this.currentMatrixLayer, annotId: this.currentMatrixAnnotId })
      
      const response = await fetch(url)
      if (!response.ok) {
        const errorData = await response.json().catch(() => ({ error: `HTTP ${response.status}: ${response.statusText}` }))
        // Include message if available for more detailed error
        const errorMessage = errorData.message ? `${errorData.error}: ${errorData.message}` : (errorData.error || `HTTP ${response.status}`)
        console.error(`GeneManager: API error for gene ${gene.symbol}:`, errorData)
        throw new Error(errorMessage)
      }

      const data = await response.json()
      
      if (data.error) {
        // Include message if available
        const errorMessage = data.message ? `${data.error}: ${data.message}` : data.error
        console.error('GeneManager: server returned error', { geneId, layer: this.currentMatrixLayer, payload: data })
        throw new Error(errorMessage)
      }
      
      if (!data.expression_values || data.expression_values.length === 0) {
        console.warn(`GeneManager: No expression values returned for gene ${gene.symbol}`)
        throw new Error('No expression values returned from server')
      }

      const expressionValues = data.expression_values || []
      const stats = this.calculateExpressionStats(expressionValues)
      
      // Store expression data for this gene - use string key for consistency
      const stableIdKey = String(gene.stableId)
      const expressionData = {
        values: expressionValues,
        stats: stats,
        geneIndex: data.gene_index,
        stableId: data.stable_id,
        symbol: gene.symbol,
        annotId: this.currentMatrixAnnotId,
        metadataId: geneMetadataId,
        baseMetadataId: baseMetadataId
      }
      
      this.geneExpressionData[stableIdKey] = expressionData
      
      // Also store with numeric key for backwards compatibility
      if (!isNaN(gene.stableId)) {
        this.geneExpressionData[gene.stableId] = expressionData
      }
      
      // Store in loadedMetadataVectors so filtering system can find it
      if (this.controller && !this.controller.loadedMetadataVectors) {
        this.controller.loadedMetadataVectors = {}
      }
      if (this.controller) {
        const minVal = this.controller.dataManager.safeMin(expressionValues)
        const maxVal = this.controller.dataManager.safeMax(expressionValues)
        const vector = {
          id: geneMetadataId,
          name: gene.symbol,
          display_name: gene.symbol,
          data_type: 'NUMERIC',
          values: expressionValues,
          compression_info: {
            min_val: minVal,
            max_val: maxVal,
            data_type: 'NUMERIC'
          }
        }
        this.controller.loadedMetadataVectors[geneMetadataId] = vector
        if (baseMetadataId !== geneMetadataId) {
          this.controller.loadedMetadataVectors[baseMetadataId] = vector
        }
        
        // Initialize slider data immediately (needed for count updates)
        if (this.controller.initializeInlineRangeSlider) {
          this.controller.initializeInlineRangeSlider(geneMetadataId, expressionValues)
          if (baseMetadataId !== geneMetadataId && this.controller.inlineRangeSliderData) {
            this.controller.inlineRangeSliderData[baseMetadataId] = this.controller.inlineRangeSliderData[geneMetadataId]
          }
        }

        // console.log('GeneManager: stored expression vector', { geneId, baseMetadataId, layerMetadataId: geneMetadataId, values: expressionValues.length })
      }
      
      // Store in IndexedDB for persistence
      if (this.controller && this.controller.memoryManager) {
        this.controller.memoryManager.storeGeneExpressionInIndexedDB(geneMetadataId, geneId, {
          values: expressionValues,
          stats: stats,
          geneIndex: data.gene_index,
          stableId: data.stable_id,
          symbol: gene.symbol,
          annotId: this.currentMatrixAnnotId,
          metadataId: geneMetadataId,
          baseMetadataId: baseMetadataId
        }).catch(error => {
          console.warn('Failed to store gene expression in IndexedDB:', error)
        })
      }
      
      // Update status icon to in-memory
      if (this.controller && this.controller.uiManager) {
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'in-memory')
        // Update gene card DOM metadata identifiers to reflect new annot_id
        const geneContainer = document.querySelector(`[data-gene-item="${gene.stableId}"]`)
        if (geneContainer) {
          geneContainer.querySelectorAll('[data-metadata-id]').forEach(el => {
            el.dataset.metadataId = baseMetadataId
            el.dataset.layerMetadataId = geneMetadataId
          })
          geneContainer.querySelectorAll('[data-range-slider-metadata-id-value]').forEach(el => {
            el.dataset.rangeSliderMetadataIdValue = geneMetadataId
            el.dataset.layerMetadataIdValue = geneMetadataId
          })
        }
        if (this.controller?.selectedXButton?.button?.dataset?.geneId === geneId) {
          this.controller.selectedXButton.metadataId = geneMetadataId
          this.controller.selectedXButton.baseMetadataId = baseMetadataId
        }
        if (this.controller?.selectedYButton?.button?.dataset?.geneId === geneId) {
          this.controller.selectedYButton.metadataId = geneMetadataId
          this.controller.selectedYButton.baseMetadataId = baseMetadataId
        }
      } else if (statusIcon) {
        statusIcon.style.display = 'none'
      }
      if (loadingDiv) {
        loadingDiv.style.display = 'none'
      }
      
      // If gene is expanded, initialize range slider UI
      const geneDiv = document.querySelector(`[data-gene-item="${gene.stableId}"]`)
      if (geneDiv) {
        const rangeSection = geneDiv.querySelector('.gene-range-section')
        if (rangeSection && rangeSection.style.display !== 'none') {
          this.initializeGeneRangeSlider(gene.stableId)
        }
      }
    } catch (error) {
      console.error(`GeneManager: Error loading expression data for ${gene.symbol}:`, error)
      
      // Update status icon to error
      if (this.controller && this.controller.uiManager) {
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'error', error.message)
      } else if (statusIcon) {
        statusIcon.style.display = 'flex'
        statusIcon.style.backgroundColor = '#dc2626'
        statusIcon.title = `Error: ${error.message}`
        const icon = statusIcon.querySelector('i')
        if (icon) {
          icon.className = 'fas fa-exclamation-circle'
        }
      }
      if (loadingDiv) {
        loadingDiv.style.display = 'none'
      }
    }
  }

  toggleGeneExpansion(geneId) {
    const geneDiv = document.querySelector(`[data-gene-item="${geneId}"]`)
    if (!geneDiv) return
    
    const chevron = geneDiv.querySelector('.gene-chevron i')
    const rangeSection = geneDiv.querySelector('.gene-range-section')
    
    if (!chevron || !rangeSection) return
    
    const isExpanding = chevron.style.transform === '' || chevron.style.transform === 'rotate(0deg)'
    
    if (isExpanding) {
      chevron.style.transform = 'rotate(90deg)'
      
      // Show range section with animation
      rangeSection.style.display = 'block'
      rangeSection.style.maxHeight = '0px'
      rangeSection.style.opacity = '0'
      rangeSection.style.overflow = 'hidden'
      rangeSection.style.transition = 'max-height 0.3s ease-out, opacity 0.2s ease-out'
      
      // Trigger reflow
      rangeSection.offsetHeight
      
      // Expand with animation
      rangeSection.style.maxHeight = '500px'
      rangeSection.style.opacity = '1'
      
      // Show filter state icon when unfolded
      const geneIdStr = String(geneId)
      const geneFilterStateIcon = document.querySelector(`.gene-filter-state-icon[data-gene-id="${geneIdStr}"]`)
      if (geneFilterStateIcon) {
        geneFilterStateIcon.style.display = 'flex'
      }
      
      // Initialize range slider if expression data is loaded
      // Wait a bit for the expansion animation to complete so canvas has proper dimensions
      const geneIdNum = parseInt(geneId)
      const expressionData = this.geneExpressionData[geneId] || 
                             this.geneExpressionData[geneIdNum] || 
                             this.geneExpressionData[geneIdStr]
      if (expressionData && expressionData.values) {
        // Wait for animation to complete (300ms animation + small buffer)
        setTimeout(() => {
          this.initializeGeneRangeSlider(geneId)
          // Also trigger a redraw of the density plot after a short delay to ensure canvas is visible
          setTimeout(() => {
            const rangeSliderElement = document.querySelector(`[data-range-slider-metadata-id-value="${this.getGeneMetadataId(geneId, this.currentMatrixAnnotId)}"]`)
            if (rangeSliderElement) {
              const controller = this.controller?.application?.getControllerForElementAndIdentifier(rangeSliderElement, 'range-slider')
              if (controller && controller.drawDensityPlot) {
                controller.drawDensityPlot()
              }
            }
          }, 100)
        }, 350)
      } else {
        // Data not loaded yet, it will initialize when loaded
        // console.log(`GeneManager: Expression data not yet loaded for gene ${geneId}, will initialize when ready`)
      }
    } else {
      chevron.style.transform = 'rotate(0deg)'
      
      // Check if this gene is currently being used for coloring
      const geneMetadataId = `gene_${geneId}`
      // console.log(`🧬 [GENE COLLAPSE] Collapsing gene ${geneId}`)
      // console.log(`🧬 [GENE COLLAPSE] Checking coloring state:`, {
        // hasController: !!this.controller,
        // currentMetadataVectorId: this.controller?.currentMetadataVector?.id || 'none',
        // geneMetadataId: geneMetadataId,
        // isCurrentlyColoring: this.controller?.currentMetadataVector?.id === geneMetadataId
      // })
      
      const isCurrentlyColoring = this.controller?.currentMetadataVector?.id === geneMetadataId
      
      if (isCurrentlyColoring) {
        // console.log(`🧬 [GENE COLLAPSE] Gene ${geneId} is currently being used for coloring - clearing coloring`)
        // console.log(`🧬 [GENE COLLAPSE] Step 1: Resetting all water drop buttons...`)
        try {
          this.controller.resetAllWaterDropButtons()
          // console.log(`🧬 [GENE COLLAPSE] Step 1: resetAllWaterDropButtons() completed`)
        } catch (error) {
          console.error(`🧬 [GENE COLLAPSE] Error in resetAllWaterDropButtons():`, error)
        }
        
        // console.log(`🧬 [GENE COLLAPSE] Step 2: Removing category colors...`)
        try {
          this.controller.removeAllCategoryColors()
          // console.log(`🧬 [GENE COLLAPSE] Step 2: removeAllCategoryColors() completed`)
        } catch (error) {
          console.error(`🧬 [GENE COLLAPSE] Error in removeAllCategoryColors():`, error)
        }
        
        // console.log(`🧬 [GENE COLLAPSE] Step 3: Clearing metadata coloring...`)
        try {
          this.controller.clearMetadataColoring()
          // console.log(`🧬 [GENE COLLAPSE] Step 3: clearMetadataColoring() completed`)
        } catch (error) {
          console.error(`🧬 [GENE COLLAPSE] Error in clearMetadataColoring():`, error)
        }
        
        // console.log(`🧬 [GENE COLLAPSE] All coloring clearing steps completed`)
      } else {
        // console.log(`🧬 [GENE COLLAPSE] Gene ${geneId} is NOT currently being used for coloring - no need to clear`)
      }
      
      // Collapse with animation
      rangeSection.style.maxHeight = '0px'
      rangeSection.style.opacity = '0'
      
      // Hide after transition
      setTimeout(() => {
        rangeSection.style.display = 'none'
      }, 300)
    }
  }

  initializeGeneRangeSlider(geneId) {
    const resolvedController = this.resolveVisualizationController()
    if (resolvedController && resolvedController !== this.controller) {
      this.controller = resolvedController
    }

    if (!this.controller) {
      console.warn(`[GENE INIT] Visualization controller unavailable for gene ${geneId}`)
      return
    }

    const geneIdNum = parseInt(geneId)
    const geneIdStr = String(geneId)
    const expressionData = this.geneExpressionData[geneId] ||
                           this.geneExpressionData[geneIdNum] ||
                           this.geneExpressionData[geneIdStr]

    if (!expressionData || !expressionData.values) {
      console.warn(`[GENE INIT] No expression data available for gene ${geneId}`)
      console.warn('[GENE INIT] Available gene IDs:', Object.keys(this.geneExpressionData || {}))
      return
    }

    const values = expressionData.values
    const geneMetadataId = this.getGeneMetadataId(geneIdStr, this.currentMatrixAnnotId)

    if (!this.controller.loadedMetadataVectors) {
      this.controller.loadedMetadataVectors = {}
    }

    if (!this.controller.loadedMetadataVectors[geneMetadataId]) {
      if (!this.controller.dataManager) {
        console.warn('[GENE INIT] DataManager not available; skipping metadata vector registration')
      } else {
        const minVal = this.controller.dataManager.safeMin(values)
        const maxVal = this.controller.dataManager.safeMax(values)
        const geneTag = this.geneTags?.find(g =>
          String(g.stableId) === geneIdStr ||
          String(g.stableId) === String(geneIdNum) ||
          g.stableId === geneIdNum
        )
        const geneName = geneTag?.symbol || `Gene ${geneIdStr}`

        this.controller.loadedMetadataVectors[geneMetadataId] = {
          id: geneMetadataId,
          name: geneName,
          display_name: geneName,
          data_type: 'NUMERIC',
          values: values,
          compression_info: {
            min_val: minVal,
            max_val: maxVal,
            data_type: 'NUMERIC'
          },
          nber_rows: 1,
          nber_cols: values.length
        }
      }
    }

    if (typeof this.controller.initializeInlineRangeSlider === 'function') {
      this.controller.initializeInlineRangeSlider(geneMetadataId, values)
      this.updateGeneSearchVisibility()
    } else {
      console.warn('[GENE INIT] initializeInlineRangeSlider is not available on the visualization controller')
    }

    if (!this.controller.inlineRangeSliderData || !this.controller.inlineRangeSliderData[geneMetadataId]) {
      console.warn(`[GENE INIT] inlineRangeSliderData not set for ${geneMetadataId}`)
    }

    if (this.controller && this.controller.uiManager) {
      setTimeout(() => {
        this.controller?.uiManager?.updateGeneFilterSwitchVisibility(geneId, geneMetadataId)
      }, 100)
    }
  }

  setupGeneButtonHandlers(geneId) {
    // Filter switch handler
    const filterSwitch = document.querySelector(`.gene-filter-switch[data-gene-id="${geneId}"]`)
    if (filterSwitch) {
      filterSwitch.addEventListener('click', (e) => {
        e.stopPropagation()
        this.toggleGeneFilter(geneId)
      })
    }
    
    // Download and color buttons are now handled by Stimulus via data-action attributes
    // No need for manual event handlers
  }

  toggleGeneFilter(geneId) {
    const filterSwitch = document.querySelector(`.gene-filter-switch[data-gene-id="${geneId}"]`)
    if (!filterSwitch) return
    
    const isEnabled = filterSwitch.dataset.filterEnabled === 'true'
    const newState = !isEnabled
    const geneIdStr = String(geneId)
    const geneMetadataId = this.getGeneMetadataId(geneIdStr, this.currentMatrixAnnotId)
    const baseGeneMetadataId = this.getBaseGeneMetadataId(geneIdStr)
    
    const resolveExistingMetadataId = (collection) => {
      if (!collection) return null
      if (collection[geneMetadataId]) return geneMetadataId
      if (collection[baseGeneMetadataId]) return baseGeneMetadataId
      return null
    }
    
    const geneDiv = document.querySelector(`[data-gene-item="${geneId}"]`)
    const rangeSection = geneDiv ? geneDiv.querySelector('.gene-range-section') : null
    const sliderElement = rangeSection ? rangeSection.querySelector('[data-controller="range-slider"]') : null
    
    let rangeSliderController = null
    if (this.controller?.application?.getControllerForElementAndIdentifier) {
      if (sliderElement) {
        try {
          rangeSliderController = this.controller.application.getControllerForElementAndIdentifier(
            sliderElement,
            'range-slider'
          )
        } catch (error) {
          console.warn('GeneManager: Unable to resolve range slider controller for gene', geneIdStr, error)
        }
      }
    }
    
    let sliderMetadataId = rangeSliderController?.metadataIdValue || geneMetadataId
    
    filterSwitch.dataset.filterEnabled = newState.toString()
    
    if (newState) {
      filterSwitch.style.backgroundColor = '#10b981'
      const toggle = filterSwitch.querySelector('div')
      if (toggle) {
        toggle.style.transform = 'translateX(14px)'
      }
      
      // Enable filtering - restore saved range or initialize with full range
      if (this.controller) {
        const existingSavedKey = resolveExistingMetadataId(this.controller.savedRanges)
        if (existingSavedKey && this.controller.savedRanges[existingSavedKey]) {
          if (!this.controller.selectedRanges) this.controller.selectedRanges = {}
          this.controller.selectedRanges[geneMetadataId] = { ...this.controller.savedRanges[existingSavedKey] }
        } else if (rangeSliderController) {
          const min = rangeSliderController.minValue
          const max = rangeSliderController.maxValue
          if (!this.controller.selectedRanges) this.controller.selectedRanges = {}
          this.controller.selectedRanges[geneMetadataId] = { min, max }
        } else {
          console.warn('GeneManager: No saved range or slider controller available to initialize gene filter')
        }
      } else {
        console.warn('GeneManager: controller unavailable when enabling gene filter switch')
      }
      
      if (this.controller?.disabledFilters instanceof Set) {
        this.controller.disabledFilters.delete(sliderMetadataId)
        this.controller.disabledFilters.delete(baseGeneMetadataId)
      }
      
      if (!rangeSliderController && sliderElement && this.controller?.application?.getControllerForElementAndIdentifier) {
        try {
          rangeSliderController = this.controller.application.getControllerForElementAndIdentifier(sliderElement, 'range-slider')
          sliderMetadataId = rangeSliderController?.metadataIdValue || geneMetadataId
        } catch (error) {
          console.warn('GeneManager: Unable to resolve range slider controller when enabling gene filter', error)
        }
      }
      
      if (rangeSliderController?.setFilterControlsDisabled) {
        rangeSliderController.setFilterControlsDisabled(false)
      }
    } else {
      filterSwitch.style.backgroundColor = '#d1d5db'
      const toggle = filterSwitch.querySelector('div')
      if (toggle) {
        toggle.style.transform = 'translateX(0px)'
      }
      
      // Disable filtering - save current range and remove from selectedRanges
      if (this.controller) {
        if (!this.controller.savedRanges) this.controller.savedRanges = {}
        const existingSelectedKey = resolveExistingMetadataId(this.controller.selectedRanges)
        if (existingSelectedKey && this.controller.selectedRanges && this.controller.selectedRanges[existingSelectedKey]) {
          const storedRange = { ...this.controller.selectedRanges[existingSelectedKey] }
          this.controller.savedRanges[geneMetadataId] = storedRange
          if (existingSelectedKey !== geneMetadataId) {
            this.controller.savedRanges[existingSelectedKey] = storedRange
          }
          delete this.controller.selectedRanges[existingSelectedKey]
        }
      }
      
      if (!this.controller?.disabledFilters || !(this.controller.disabledFilters instanceof Set)) {
        this.controller.disabledFilters = new Set(this.controller?.disabledFilters || [])
      }
      this.controller.disabledFilters.add(sliderMetadataId)
      this.controller.disabledFilters.add(baseGeneMetadataId)
      
      if (!rangeSliderController && sliderElement && this.controller?.application?.getControllerForElementAndIdentifier) {
        try {
          rangeSliderController = this.controller.application.getControllerForElementAndIdentifier(sliderElement, 'range-slider')
          sliderMetadataId = rangeSliderController?.metadataIdValue || geneMetadataId
        } catch (error) {
          console.warn('GeneManager: Unable to resolve range slider controller when disabling gene filter', error)
        }
      }
      
      if (rangeSliderController?.setFilterControlsDisabled) {
        rangeSliderController.setFilterControlsDisabled(true)
      }
    }
    
    if (rangeSliderController && typeof rangeSliderController.drawDensityPlot === 'function') {
      rangeSliderController.drawDensityPlot()
    }
    
    // Update filtering
    if (this.controller && this.controller.dataManager) {
      this.controller.dataManager.updateCellFiltering()
    }
    
    // console.log(`GeneManager: Toggle filter for gene ${geneId}: ${newState ? 'enabled' : 'disabled'}`)
  }



  showNotFoundGenes() {
    if (!this.notFoundQueries || this.notFoundQueries.length === 0) {
      alert('No genes were not found.')
      return
    }

    // Create modal to display not found genes
    const overlay = document.createElement('div')
    overlay.style.cssText = 'position: fixed; top: 0; left: 0; right: 0; bottom: 0; background-color: rgba(0, 0, 0, 0.5); z-index: 10000; display: flex; align-items: center; justify-content: center; padding: 20px;'
    
    const modal = document.createElement('div')
    modal.style.cssText = 'background: white; border-radius: 8px; padding: 24px; max-width: 500px; width: 100%; max-height: 80vh; overflow-y: auto; box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1);'
    
    modal.innerHTML = `
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
        <h3 style="margin: 0; font-size: 18px; font-weight: 600; color: #111827;">
          Genes Not Found (${this.notFoundQueries.length})
        </h3>
        <button id="close-not-found-modal" style="background: none; border: none; font-size: 24px; color: #6b7280; cursor: pointer; padding: 0; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; border-radius: 4px;" 
                onmouseover="this.style.backgroundColor='#f3f4f6'; this.style.color='#374151'" 
                onmouseout="this.style.backgroundColor=''; this.style.color='#6b7280'">×</button>
      </div>
      <div style="font-size: 14px; color: #6b7280; margin-bottom: 16px;">
        The following gene${this.notFoundQueries.length === 1 ? '' : 's'} could not be found in the dataset:
      </div>
      <div style="background-color: #f9fafb; border: 1px solid #e5e7eb; border-radius: 6px; padding: 12px; max-height: 400px; overflow-y: auto;">
        <div style="display: flex; flex-direction: column; gap: 8px;">
          ${this.notFoundQueries.map(gene => `
            <div style="padding: 8px; background-color: white; border-radius: 4px; font-size: 13px; font-family: monospace; color: #374151;">
              ${gene}
            </div>
          `).join('')}
        </div>
      </div>
      <div style="margin-top: 16px; display: flex; justify-content: flex-end;">
        <button id="copy-not-found-genes" style="padding: 8px 16px; background-color: #3b82f6; color: white; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; margin-right: 8px;"
                onmouseover="this.style.backgroundColor='#2563eb'"
                onmouseout="this.style.backgroundColor='#3b82f6'">
          Copy to Clipboard
        </button>
        <button id="close-not-found-btn" style="padding: 8px 16px; background-color: #e5e7eb; color: #374151; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer;"
                onmouseover="this.style.backgroundColor='#d1d5db'"
                onmouseout="this.style.backgroundColor='#e5e7eb'">
          Close
        </button>
      </div>
    `
    
    overlay.appendChild(modal)
    document.body.appendChild(overlay)
    
    // Close handlers
    const closeModal = () => {
      document.body.removeChild(overlay)
    }
    
    document.getElementById('close-not-found-modal').addEventListener('click', closeModal)
    document.getElementById('close-not-found-btn').addEventListener('click', closeModal)
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) {
        closeModal()
      }
    })
    
    // Copy to clipboard
    document.getElementById('copy-not-found-genes').addEventListener('click', () => {
      const geneList = this.notFoundQueries.join('\n')
      navigator.clipboard.writeText(geneList).then(() => {
        const btn = document.getElementById('copy-not-found-genes')
        const originalText = btn.textContent
        btn.textContent = 'Copied!'
        btn.style.backgroundColor = '#059669'
        setTimeout(() => {
          btn.textContent = originalText
          btn.style.backgroundColor = '#3b82f6'
        }, 2000)
      }).catch(err => {
        console.error('Failed to copy:', err)
        alert('Failed to copy to clipboard')
      })
    })
  }

  showAddGeneSetModal() {
    // Use geneTags from this instance
    if (!this.geneTags || this.geneTags.length === 0) {
      console.error('GeneManager: showAddGeneSetModal called but no genes found in geneTags')
      return
    }
    this.showAddGeneSetModalWithGenes(this.geneTags)
  }

  showAddGeneSetModalWithGenes(genes) {
    // This method accepts genes as a parameter, so it works even if geneTags is not updated
    if (!genes || genes.length === 0) {
      console.error('GeneManager: showAddGeneSetModalWithGenes called but no genes provided')
      return
    }

    // Remove any existing modal first to prevent duplicates
    const existingOverlay = document.getElementById('gene-set-modal-overlay')
    if (existingOverlay) {
      // console.log('GeneManager: Removing existing modal overlay before creating new one')
      if (existingOverlay.parentNode) {
        existingOverlay.parentNode.removeChild(existingOverlay)
      } else {
        existingOverlay.remove()
      }
    }

    // Create modal overlay
    const overlay = document.createElement('div')
    overlay.id = 'gene-set-modal-overlay'
    overlay.style.cssText = 'position: fixed; top: 0; left: 0; right: 0; bottom: 0; background-color: rgba(0, 0, 0, 0.5); z-index: 10000; display: flex; align-items: center; justify-content: center; padding: 20px;'
    
    const modal = document.createElement('div')
    modal.id = 'gene-set-modal-content'
    modal.style.cssText = 'background: white; border-radius: 8px; padding: 24px; max-width: 600px; width: 100%; max-height: 80vh; overflow-y: auto; box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1); position: relative;'
    
    modal.innerHTML = `
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
        <h3 style="margin: 0; font-size: 18px; font-weight: 600; color: #111827;">Add Gene Set</h3>
        <button type="button" id="close-add-gene-set-modal" style="background: none; border: none; font-size: 24px; color: #6b7280; cursor: pointer; padding: 0; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; border-radius: 4px;" 
                onmouseover="this.style.backgroundColor='#f3f4f6'; this.style.color='#374151'" 
                onmouseout="this.style.backgroundColor=''; this.style.color='#6b7280'">×</button>
      </div>
      
      <form id="add-gene-set-form" style="display: flex; flex-direction: column; gap: 20px;">
        <div>
          <label style="display: block; font-size: 14px; font-weight: 500; color: #374151; margin-bottom: 8px;">
            Gene Set Name <span style="color: #dc2626;">*</span>
          </label>
          <input 
            type="text" 
            id="gene-set-name-input" 
            required
            placeholder="Enter gene set name..."
            style="width: 100%; padding: 10px 12px; border: 1px solid #d1d5db; border-radius: 6px; font-size: 14px; outline: none; transition: border-color 0.2s;"
            onfocus="this.style.borderColor='#3b82f6'"
            onblur="this.style.borderColor='#d1d5db'"
          />
        </div>
        
        <div>
          <label style="display: block; font-size: 14px; font-weight: 500; color: #374151; margin-bottom: 8px;">
            Genes (${genes.length})
          </label>
          <div style="border: 1px solid #e5e7eb; border-radius: 6px; overflow: hidden; max-height: 400px; overflow-y: auto;">
            <table style="width: 100%; border-collapse: collapse;">
              <thead style="background-color: #f9fafb; border-bottom: 1px solid #e5e7eb; position: sticky; top: 0;">
                <tr>
                  <th style="padding: 12px; text-align: left; font-size: 12px; font-weight: 600; color: #374151; text-transform: uppercase; letter-spacing: 0.5px;">Gene Symbol</th>
                  <th style="padding: 12px; text-align: left; font-size: 12px; font-weight: 600; color: #374151; text-transform: uppercase; letter-spacing: 0.5px;">Ensembl ID</th>
                  <th style="padding: 12px; text-align: left; font-size: 12px; font-weight: 600; color: #374151; text-transform: uppercase; letter-spacing: 0.5px;">Stable ID</th>
                </tr>
              </thead>
              <tbody>
                ${genes.map((gene, index) => `
                  <tr style="border-bottom: 1px solid #f3f4f6; ${index % 2 === 0 ? 'background-color: #ffffff;' : 'background-color: #f9fafb;'}">
                    <td style="padding: 12px; font-size: 13px; color: #111827;">${gene.symbol}</td>
                    <td style="padding: 12px; font-size: 13px; color: #6b7280; font-family: monospace;">${gene.ensemblId}</td>
                    <td style="padding: 12px; font-size: 13px; color: #6b7280; font-family: monospace;">${gene.stableId}</td>
                  </tr>
                `).join('')}
              </tbody>
            </table>
          </div>
        </div>
        
        <div style="display: flex; justify-content: flex-end; gap: 12px; margin-top: 8px;">
          <button 
            type="button"
            id="cancel-add-gene-set-btn" 
            style="padding: 10px 20px; background-color: #e5e7eb; color: #374151; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; transition: background-color 0.2s;"
            onmouseover="this.style.backgroundColor='#d1d5db'"
            onmouseout="this.style.backgroundColor='#e5e7eb'"
            >
            Cancel
          </button>
          <button 
            type="submit"
            id="submit-add-gene-set-btn" 
            style="padding: 10px 20px; background-color: #3b82f6; color: white; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; transition: background-color 0.2s;"
            onmouseover="this.style.backgroundColor='#2563eb'"
            onmouseout="this.style.backgroundColor='#3b82f6'">
            Submit
          </button>
        </div>
      </form>
    `
    
    overlay.appendChild(modal)
    document.body.appendChild(overlay)
    
    // Simple close function
    const closeModal = () => {
      // console.log('GeneManager: closeModal called')
      
      // Remove by ID to handle any instance
      const overlayToRemove = document.getElementById('gene-set-modal-overlay')
      if (overlayToRemove) {
        // console.log('GeneManager: Removing overlay by ID')
        if (overlayToRemove.parentNode) {
          overlayToRemove.parentNode.removeChild(overlayToRemove)
        } else {
          overlayToRemove.remove()
        }
      }
      
      // Also remove the overlay reference if it exists
      if (overlay && overlay.parentNode) {
        overlay.parentNode.removeChild(overlay)
      }
    }
    
    // Use event delegation on modal to handle all clicks
    modal.addEventListener('click', (e) => {
      const target = e.target
      
      // Find the button element (handles clicks on text nodes or children)
      let button = null
      if (target.tagName === 'BUTTON') {
        button = target
      } else if (target.closest) {
        button = target.closest('button')
      } else if (target.parentElement && target.parentElement.tagName === 'BUTTON') {
        button = target.parentElement
      }
      
      // Check if click is on close or cancel button
      if (button && (button.id === 'close-add-gene-set-modal' || button.id === 'cancel-add-gene-set-btn')) {
        // console.log('GeneManager: Close/Cancel button clicked via delegation', button.id, target)
        e.preventDefault()
        e.stopPropagation()
        e.stopImmediatePropagation()
        // Call closeModal immediately and return
        setTimeout(() => {
          closeModal()
        }, 0)
        return false
      }
      
      // Prevent clicks inside modal from closing overlay (but allow button clicks above)
      e.stopPropagation()
    })
    
    // Close on overlay background click
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) {
        // console.log('GeneManager: Overlay background clicked')
        closeModal()
      }
    })
    
    // Form submission - genes is in scope from the function parameter
    document.getElementById('add-gene-set-form').addEventListener('submit', (e) => {
      e.preventDefault()
      const nameInput = document.getElementById('gene-set-name-input')
      const geneSetName = nameInput.value.trim()
      
      if (!geneSetName) {
        alert('Please enter a gene set name.')
        nameInput.focus()
        return
      }
      
      // Create gene set object
      const geneSet = {
        name: geneSetName,
        genes: genes.map(gene => ({
          symbol: gene.symbol,
          ensemblId: gene.ensemblId,
          stableId: gene.stableId
        }))
      }
      
      // console.log('GeneManager: Submitting gene set:', geneSet)
      
      // TODO: Implement API call to save gene set
      // For now, just log and close
      alert(`Gene set "${geneSetName}" with ${geneSet.genes.length} genes would be saved.`)
      closeModal()
    })
    
    // Focus on name input
    setTimeout(() => {
      document.getElementById('gene-set-name-input').focus()
    }, 100)
  }

}

