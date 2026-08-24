import consumer from "channels/consumer"
import { renderGeneCategoryBoxplot } from "visualization/regl_boxplot"
import { GeneSetOverlapPopup } from "visualization/gene_set_overlap_popup"

// GeneManager - Handles gene autocomplete and expression visualization
export class GeneManager {
  static MAX_GENE_PANEL_GENES = 1000

  constructor(controller) {
    this.controller = controller
    this.maxGenePanelGenes = GeneManager.MAX_GENE_PANEL_GENES
    this.autocompleteData = null
    this.aliasesByEnsembl = {}
    this.featureNamesByStable = {}
    this.ensemblRelease = null
    this.currentMatches = []
    this.selectedGene = null
    this.projectIdentifier = null
    this.geneTags = [] // Array of {symbol, ensemblId, stableId, query}
    this.genePanelSavedKey = '' // geneListHistoryKey fingerprint when panel contents were last saved/loaded from a gene set
    this.notFoundQueries = [] // Queries that didn't match
    this.geneListHistory = [] // Up to 10 previous gene-list snapshots (newest first)
    this._geneListHistoryBatchDepth = 0
    this._geneListHistoryBefore = null
    this._skipGeneListHistoryRecord = false
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
    this.collectionImportSubscription = null
    this.projectChannelId = null
    this.pendingCollectionImportIds = new Set()
    this.pendingCollectionImportPollers = new Map()
    this.geneSetOverlapPopup = null
    // Expose globally for diagnostics and inline handlers
    window.geneManager = this
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

  // Update gene row DOM ids before initializeInlineRangeSlider so findRangeSliderElementByMetadataId finds the slider.
  updateGeneCardRangeSliderMetadataIds(stableId, baseMetadataId, layerMetadataId) {
    const sid = String(stableId)
    const geneDiv =
      document.querySelector(`[data-gene-item="${sid}"]`) ||
      document.querySelector(`[data-gene-item="${Number(sid)}"]`)
    if (!geneDiv) return
    geneDiv.querySelectorAll('[data-metadata-id]').forEach((el) => {
      el.dataset.metadataId = baseMetadataId
      el.dataset.layerMetadataId = layerMetadataId
    })
    geneDiv.querySelectorAll('[data-range-slider-metadata-id-value]').forEach((el) => {
      el.dataset.rangeSliderMetadataIdValue = layerMetadataId
      el.dataset.layerMetadataIdValue = layerMetadataId
    })
  }

  // Handle matrix/layer selection change
  async onMatrixLayerChange(layerPath, annotId) {
    const nextLayer = layerPath || '/matrix'
    const nextAnnotId = annotId && annotId !== '' ? String(annotId) : null
    this.currentMatrixLayer = nextLayer
    this.currentMatrixAnnotId = nextAnnotId
    this.matrixInitialized = true
    
    // Clear all gene expression data vectors with old annot_id
    if (this.controller && this.controller.loadedMetadataVectors) {
      const keysToRemove = Object.keys(this.controller.loadedMetadataVectors).filter(key => key.startsWith('gene_'))

      keysToRemove.forEach(key => delete this.controller.loadedMetadataVectors[key])
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

    if (this.controller?.selectedRanges) {
      Object.keys(this.controller.selectedRanges)
        .filter((k) => k.startsWith('gene_'))
        .forEach((k) => { delete this.controller.selectedRanges[k] })
    }
    if (this.controller?.savedRanges) {
      Object.keys(this.controller.savedRanges)
        .filter((k) => k.startsWith('gene_'))
        .forEach((k) => { delete this.controller.savedRanges[k] })
    }

    // Drop stored gene-expression gradients so the next coloring uses an auto
    // gradient that matches the new matrix value range (signed vs positive-only).
    if (this.controller?.metadataGradients instanceof Map) {
      for (const key of [...this.controller.metadataGradients.keys()]) {
        const id = String(key)
        if (id.startsWith('gene_') && !id.startsWith('gene_set_')) {
          this.controller.metadataGradients.delete(key)
        }
      }
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
      const resultsDiv = document.getElementById('gene-expression-results')
      const reloadPromises = Array.from(genesToReload.values()).map(gene => this.loadGeneExpressionData(gene, resultsDiv))
      await Promise.all(reloadPromises)
    }

    this.syncActiveGeneMetadataColoringAfterMatrixChange()

    // Refresh custom 2D plot if open
    if (this.controller?.customPlotManager) {
      await this.controller.customPlotManager.refresh2DPlotIfOpen()
    }
  }

  // After matrix/layer change, loadedMetadataVectors is replaced but currentMetadataVector can still
  // reference the detached old object. Rebind active gene coloring to the reloaded vector.
  syncActiveGeneMetadataColoringAfterMatrixChange() {
    const controller = this.controller
    if (!controller) return

    const activeId = String(controller.currentMetadataVector?.id || controller.currentMetadataId || '')
    if (!activeId.startsWith('gene_')) return

    const match = activeId.match(/^gene_([^_]+)(?:_|$)/)
    const geneStableId = match ? String(match[1]) : null
    if (!geneStableId) return

    const nextMetadataId = this.getGeneMetadataId(geneStableId, this.currentMatrixAnnotId)
    const baseKey = this.getBaseGeneMetadataId(geneStableId)
    const updated =
      controller.loadedMetadataVectors?.[nextMetadataId] ||
      (baseKey !== nextMetadataId ? controller.loadedMetadataVectors?.[baseKey] : null)

    if (!updated || !Array.isArray(updated.values) || updated.values.length === 0) return

    controller.currentMetadataVector = updated
    controller.currentMetadataId = nextMetadataId

    if (controller.colorManager && typeof controller.colorManager.clearColorMapCache === 'function') {
      controller.colorManager.clearColorMapCache()
    }
    controller._lastNumericOrderApplied = null

    const existingRange = controller.selectedRanges?.[nextMetadataId]
    if (existingRange && Number.isFinite(existingRange.min) && Number.isFinite(existingRange.max)) {
      controller.setColorRange(existingRange.min, existingRange.max)
    } else if (controller.dataManager) {
      const minVal = controller.dataManager.safeMin(updated.values)
      const maxVal = controller.dataManager.safeMax(updated.values)
      controller.setColorRange(minVal, maxVal)
    }

    if (controller.gradientManager && typeof controller.gradientManager.loadGradientForMetadata === 'function') {
      controller.gradientManager.loadGradientForMetadata(nextMetadataId)
    }
    if (controller.gradientManager && typeof controller.gradientManager.initializeGradientLegendListeners === 'function') {
      controller.gradientManager.initializeGradientLegendListeners()
    }

    if (typeof controller.updateVisualizationWithMetadataVector === 'function') {
      controller.updateVisualizationWithMetadataVector()
    }
    if (controller.dataManager) {
      if (typeof controller.dataManager.updateAllCategoryDistributions === 'function') {
        controller.dataManager.updateAllCategoryDistributions()
      }
      if (typeof controller.dataManager.updateCellFiltering === 'function') {
        controller.dataManager.updateCellFiltering(true)
      }
    }
    if (typeof controller.updateAllRangeSliderButtonAppearances === 'function') {
      controller.updateAllRangeSliderButtonAppearances()
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

    // Gene autocomplete is independent of plot readiness; expression coloring waits for the renderer.
    const ready = this.autocompleteLoaded

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

  init() {
    // console.log('GeneManager: Initializing...')
    const visualizationElement = document.querySelector('[data-controller="visualization"]')
    const projectIdValue = visualizationElement?.dataset?.projectId
    this.projectChannelId = projectIdValue ? String(projectIdValue).trim() : null

    // Extract project identifier from URL (could be ID, key, or public_id like ASAP48)
    const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
    if (pathMatch) {
      this.projectIdentifier = pathMatch[1] // Use identifier instead of just ID
      // console.log('GeneManager: Project identifier extracted:', this.projectIdentifier)
      this.setupGeneSetCollectionImportSubscription()
    } else {
      console.warn('GeneManager: Could not extract project identifier from URL:', window.location.pathname)
    }
    
    // Check if user is admin from data attribute
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
          this.beginGeneListHistoryBatch()
          try {
            for (const part of parts) {
              const trimmed = part.trim()
              if (trimmed) {
                this.processGeneInput(trimmed)
              }
            }
          } finally {
            this.endGeneListHistoryBatch()
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
          this.beginGeneListHistoryBatch()
          try {
            this.processGeneInput(input.value.trim())
          } finally {
            this.endGeneListHistoryBatch()
          }
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

        e.preventDefault()
        clearTimeout(debounceTimer)
        this.hideDropdown()

        const pastedText = (e.clipboardData || window.clipboardData)?.getData('text') || ''
        const genes = this.parseBulkGeneInput(pastedText)
        input.value = ''

        // Process pasted genes directly without showing autocomplete suggestions.
        this.processBulkGeneInput(genes)
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
    
    // Initialize add gene set buttons.
    const addButtons = document.querySelectorAll('[data-gene-set-add-trigger="true"]')
    if (addButtons.length > 0) {
      const geneManager = this
      addButtons.forEach((button) => {
        if (button.dataset.geneSetAddBound === 'true') return
        button.dataset.geneSetAddBound = 'true'

        button.addEventListener('click', function(e) {
          e.preventDefault()
          e.stopPropagation()

          if (button.id === 'gene-set-collections-add-btn') {
            geneManager.showAddGeneSetCollectionModal()
            return
          }

          const genes = Array.isArray(geneManager.geneTags) ? [...geneManager.geneTags] : []
          const geneCount = genes.length

          if (geneCount === 0) {
            alert('No genes selected. Please select genes before creating a gene set.')
            return
          }

          geneManager.showAddGeneSetModalWithGenes(genes)
        })
      })
    }

    this.geneSetOverlapPopup = new GeneSetOverlapPopup({
      getProjectIdentifier: () => this.projectIdentifier || this.controller?.getProjectIdentifier?.() || null,
      getGenes: () => (Array.isArray(this.geneTags) ? this.geneTags : []).map((gene) => ({
        symbol: gene.symbol || gene.query || '',
        ensembl_id: gene.ensemblId || gene.ensembl_id || '',
        stable_id: gene.stableId || gene.stable_id || ''
      })),
      getBackgroundGenes: () => [],
      getLoomFile: () => this.resolveCurrentLoomFile?.() || this.controller?.getCurrentLoomFileForRequest?.() || this.controller?.currentLoomFile || '',
      backgroundContextLabel: "Genes in gene panel",
      getCsrfToken: () => document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
    })
    const overlapBtn = document.getElementById('gene-set-overlap-btn')
    if (overlapBtn && overlapBtn.dataset.bound !== 'true') {
      overlapBtn.dataset.bound = 'true'
      overlapBtn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.geneSetOverlapPopup?.open()
      })
    }

    const clearAllBtn = document.getElementById('clear-genes-btn')
    if (clearAllBtn && clearAllBtn.dataset.bound !== 'true') {
      clearAllBtn.dataset.bound = 'true'
      clearAllBtn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.clearAllGenes()
      })
    }

    const revertBtn = document.getElementById('gene-list-revert-btn')
    if (revertBtn && revertBtn.dataset.bound !== 'true') {
      revertBtn.dataset.bound = 'true'
      revertBtn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.revertToPreviousGeneList()
      })
    }

    const historyBtn = document.getElementById('gene-list-history-btn')
    if (historyBtn && historyBtn.dataset.bound !== 'true') {
      historyBtn.dataset.bound = 'true'
      historyBtn.addEventListener('click', (e) => {
        e.preventDefault()
        e.stopPropagation()
        this.toggleGeneListHistoryMenu(e)
      })
    }

    const historyMenu = document.getElementById('gene-list-history-menu')
    if (historyMenu && historyMenu.dataset.bound !== 'true') {
      historyMenu.dataset.bound = 'true'
      historyMenu.addEventListener('click', (e) => e.stopPropagation())
    }

    if (!this._boundCloseGeneListHistoryMenu) {
      this._boundCloseGeneListHistoryMenu = () => this.closeGeneListHistoryMenu()
      document.addEventListener('click', this._boundCloseGeneListHistoryMenu)
    }

    this.updateGeneListHistoryControls()
  }

  setupGeneSetCollectionImportSubscription() {
    if (!this.projectChannelId || this.collectionImportSubscription) return
    if (!consumer || !consumer.subscriptions) return

    this.collectionImportSubscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: this.projectChannelId },
      {
        received: (data) => {
          if (!data || data.event !== 'gene_set_collection_import') return
          const importId = String(data.import_id || '').trim()
          const hasTrackedImport = importId && this.pendingCollectionImportIds.has(importId)
          const shouldHandle = !importId || hasTrackedImport
          if (!shouldHandle) return

          if (importId) this.pendingCollectionImportIds.delete(importId)
          if (data.status === 'completed' && data.collection) {
            const collectionsController = this.controller?.geneSetCollectionsController
            if (collectionsController && typeof collectionsController.upsertCollectionFromPayload === 'function') {
              collectionsController.upsertCollectionFromPayload(data.collection)
            }
            this.stopCollectionImportPolling(String(data.collection.id || ''))
            if (this.controller && typeof this.controller.setSelectionTab === 'function') {
              this.controller.setSelectionTab('gene-sets')
            }
            return
          }

          if (data.status === 'failed') {
            const failedCollectionId = String(data.collection_id || '').trim()
            if (failedCollectionId) {
              const row = document.querySelector(`[data-gene-set-collection-row="true"][data-collection-id="local_collection:${failedCollectionId}"]`)
              if (row) row.remove()
              this.stopCollectionImportPolling(`local_collection:${failedCollectionId}`)
              const collectionsController = this.controller?.geneSetCollectionsController
              if (collectionsController && typeof collectionsController.applyListFilter === 'function') {
                collectionsController.applyListFilter()
              }
            }
            alert(data.message || 'Failed to import gene set collection')
          }
        }
      }
    )
  }

  stopCollectionImportPolling(collectionId) {
    const key = String(collectionId || '').trim()
    if (!key) return
    const timerId = this.pendingCollectionImportPollers.get(key)
    if (timerId) {
      clearInterval(timerId)
      this.pendingCollectionImportPollers.delete(key)
    }
  }

  startCollectionImportPolling(collectionId) {
    const key = String(collectionId || '').trim()
    if (!key || !this.projectIdentifier) return
    this.stopCollectionImportPolling(key)
    let attempts = 0
    const maxAttempts = 120
    const poll = async () => {
      attempts += 1
      try {
        const params = new URLSearchParams({ collection_id: key })
        const response = await fetch(`/projects/${encodeURIComponent(this.projectIdentifier)}/gene_set_collection_status?${params.toString()}`, {
          method: 'GET',
          credentials: 'same-origin',
          headers: { 'Accept': 'application/json' }
        })
        const payload = await response.json()
        if (!response.ok) return

        if (payload.status === 'completed' && payload.collection) {
          const collectionsController = this.controller?.geneSetCollectionsController
          if (collectionsController && typeof collectionsController.upsertCollectionFromPayload === 'function') {
            collectionsController.upsertCollectionFromPayload(payload.collection)
          }
          this.stopCollectionImportPolling(key)
          return
        }

        if (payload.status === 'failed') {
          const row = document.querySelector(`[data-gene-set-collection-row="true"][data-collection-id="${key}"]`)
          if (row) row.remove()
          this.stopCollectionImportPolling(key)
          if (payload.message) alert(payload.message)
          return
        }

        if (attempts >= maxAttempts) {
          this.stopCollectionImportPolling(key)
          const row = document.querySelector(`[data-gene-set-collection-row="true"][data-collection-id="${key}"]`)
          if (row) row.remove()
          alert('Import timed out while waiting for completion')
        }
      } catch (error) {
        if (attempts >= maxAttempts) {
          this.stopCollectionImportPolling(key)
        }
      }
    }
    const timerId = setInterval(poll, 2000)
    this.pendingCollectionImportPollers.set(key, timerId)
    poll()
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

    const overlapBtn = document.getElementById('gene-set-overlap-btn')
    if (overlapBtn) {
      overlapBtn.style.display = this.geneTags.length > 0 ? 'inline-flex' : 'none'
    }

    const clearAllBtn = document.getElementById('clear-genes-btn')
    if (clearAllBtn) {
      clearAllBtn.style.display = this.geneTags.length > 0 ? 'inline-flex' : 'none'
    }

    this.updateGeneListHistoryControls()
  }

  clearGeneMetadataStateForStableIds(stableIds = []) {
    const controller = this.controller
    if (!controller) return false

    const normalizedIds = Array.isArray(stableIds)
      ? stableIds.map((id) => String(id || '').trim()).filter((id) => id.length > 0)
      : []
    if (normalizedIds.length === 0) return false

    const matchesGeneMetadataId = (metadataId) => {
      const id = String(metadataId || '')
      return normalizedIds.some((geneId) => id === `gene_${geneId}` || id.startsWith(`gene_${geneId}_`))
    }

    let stateChanged = false

    ;['loadedMetadataVectors', 'inlineRangeSliderData', 'selectedRanges', 'savedRanges'].forEach((collectionName) => {
      const collection = controller[collectionName]
      if (!collection || typeof collection !== 'object') return
      Object.keys(collection).forEach((metadataId) => {
        if (matchesGeneMetadataId(metadataId)) {
          delete collection[metadataId]
          stateChanged = true
        }
      })
    })

    if (controller.disabledFilters instanceof Set) {
      const toDelete = []
      controller.disabledFilters.forEach((metadataId) => {
        if (matchesGeneMetadataId(metadataId)) {
          toDelete.push(metadataId)
        }
      })
      toDelete.forEach((metadataId) => {
        controller.disabledFilters.delete(metadataId)
        stateChanged = true
      })
    }

    const currentColoringId = String(controller.currentMetadataVector?.id || controller.currentMetadataId || '')
    if (matchesGeneMetadataId(currentColoringId) && typeof controller.clearMetadataColoring === 'function') {
      if (typeof controller.resetAllWaterDropButtons === 'function') {
        controller.resetAllWaterDropButtons()
      }
      if (typeof controller.removeAllCategoryColors === 'function') {
        controller.removeAllCategoryColors()
      }
      controller.clearMetadataColoring()
      stateChanged = true
    }

    if (stateChanged) {
      if (controller.uiManager && typeof controller.uiManager.updateGlobalFilterSummary === 'function') {
        controller.uiManager.updateGlobalFilterSummary()
      }
      if (controller.dataManager && typeof controller.dataManager.updateCellFiltering === 'function') {
        controller.dataManager.updateCellFiltering(true)
      }
    }

    return stateChanged
  }

  syncGeneExpressionFilterStateForGenes(nextGeneStableIds = []) {
    const controller = this.controller
    if (!controller) return

    const normalizedNextGeneIds = new Set(
      Array.isArray(nextGeneStableIds) ? nextGeneStableIds.map((id) => String(id || '').trim()).filter((id) => id.length > 0) : []
    )
    const extractGeneIdFromMetadataId = (metadataId) => {
      const match = String(metadataId || '').match(/^gene_([^_]+)(?:_|$)/)
      return match ? String(match[1]) : null
    }
    const shouldKeepMetadataId = (metadataId) => {
      const geneId = extractGeneIdFromMetadataId(metadataId)
      if (!geneId) return false
      return normalizedNextGeneIds.has(geneId)
    }

    // Remove active gene-expression ranges for genes not in the new set.
    let filtersChanged = false
    if (controller.selectedRanges && typeof controller.selectedRanges === 'object') {
      Object.keys(controller.selectedRanges).forEach((metadataId) => {
        if (String(metadataId).startsWith('gene_') && !shouldKeepMetadataId(metadataId)) {
          delete controller.selectedRanges[metadataId]
          filtersChanged = true
        }
      })
    }

    // Remove disabled state tracked for removed gene-expression filters.
    if (controller.disabledFilters instanceof Set) {
      const toDelete = []
      controller.disabledFilters.forEach((metadataId) => {
        if (String(metadataId).startsWith('gene_') && !shouldKeepMetadataId(metadataId)) {
          toDelete.push(metadataId)
        }
      })
      toDelete.forEach((metadataId) => {
        controller.disabledFilters.delete(metadataId)
        filtersChanged = true
      })
    }

    // Drop saved ranges only for removed genes.
    if (controller.savedRanges && typeof controller.savedRanges === 'object') {
      Object.keys(controller.savedRanges).forEach((metadataId) => {
        if (String(metadataId).startsWith('gene_') && !shouldKeepMetadataId(metadataId)) {
          delete controller.savedRanges[metadataId]
          filtersChanged = true
        }
      })
    }

    // If coloring is currently gene-based and that gene is removed, revert to no coloring.
    const currentColoringId = String(controller.currentMetadataVector?.id || controller.currentMetadataId || '')
    if (currentColoringId.startsWith('gene_') && !shouldKeepMetadataId(currentColoringId) && typeof controller.clearMetadataColoring === 'function') {
      if (typeof controller.resetAllWaterDropButtons === 'function') {
        controller.resetAllWaterDropButtons()
      }
      if (typeof controller.removeAllCategoryColors === 'function') {
        controller.removeAllCategoryColors()
      }
      controller.clearMetadataColoring()
    }

    // Keep global filter summary/selection state in sync after removing stale filters.
    if (filtersChanged) {
      if (controller.uiManager && typeof controller.uiManager.updateGlobalFilterSummary === 'function') {
        controller.uiManager.updateGlobalFilterSummary()
      }
      if (controller.dataManager && typeof controller.dataManager.updateCellFiltering === 'function') {
        controller.dataManager.updateCellFiltering(true)
      }
    }
  }

  async replaceGenesFromGeneSet(geneEntries, options = {}) {
    const normalizedGenes = Array.isArray(geneEntries)
      ? geneEntries
        .map((entry) => {
          const stableRaw = entry?.stable_id ?? entry?.stableId
          const stableId = String(stableRaw || '').trim()
          if (!stableId) return null
          const resolved = this.resolveGeneIdentity({
            stableId,
            symbol: entry?.symbol || entry?.name || '',
            ensemblId: entry?.ensembl_id ?? entry?.ensemblId ?? ''
          })
          return {
            stableId,
            symbol: resolved.symbol || `Gene ${stableId}`,
            ensemblId: resolved.ensemblId || '',
            featureName: this.featureNameForStable(stableId),
            query: resolved.symbol || resolved.ensemblId || String(stableId)
          }
        })
        .filter((gene) => !!gene)
      : []

    const maxGenes = Number(this.maxGenePanelGenes) > 0 ? Number(this.maxGenePanelGenes) : GeneManager.MAX_GENE_PANEL_GENES
    if (normalizedGenes.length > maxGenes) {
      throw new Error(
        `This selection has ${normalizedGenes.length} genes. You can add at most ${maxGenes} genes to the gene panel at once.`
      )
    }

    this.beginGeneListHistoryBatch()
    try {
      const nextGeneStableIds = normalizedGenes.map((gene) => String(gene.stableId))
      this.syncGeneExpressionFilterStateForGenes(nextGeneStableIds)
      this.geneTags = normalizedGenes
      this.notFoundQueries = []
      this.updateGeneCountBadge()
      await this.processAllGenes()
      if (options.markSaved) {
        this.markGenePanelContentSaved(normalizedGenes)
      }
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  snapshotGeneList() {
    return (Array.isArray(this.geneTags) ? this.geneTags : []).map((gene) => ({ ...gene }))
  }

  geneListHistoryKey(genes) {
    return (Array.isArray(genes) ? genes : [])
      .map((gene) => String(gene?.stableId || '').trim())
      .filter((id) => id.length > 0)
      .join('|')
  }

  markGenePanelContentSaved(genes = null) {
    this.genePanelSavedKey = this.geneListHistoryKey(genes == null ? this.geneTags : genes)
  }

  isGenePanelContentUnsaved() {
    const tags = Array.isArray(this.geneTags) ? this.geneTags : []
    if (tags.length === 0) return false
    return this.geneListHistoryKey(tags) !== String(this.genePanelSavedKey || '')
  }

  geneListHistoryLabel(genes) {
    const list = Array.isArray(genes) ? genes : []
    if (list.length === 0) return 'Empty gene list'
    const symbols = list
      .map((gene) => String(gene?.symbol || gene?.ensemblId || gene?.stableId || '').trim())
      .filter((value) => value.length > 0)
    const preview = symbols.slice(0, 3).join(', ')
    const suffix = symbols.length > 3 ? ', ...' : ''
    return `${list.length} gene${list.length === 1 ? '' : 's'}: ${preview}${suffix}`
  }

  beginGeneListHistoryBatch() {
    if (this._geneListHistoryBatchDepth === 0) {
      this._geneListHistoryBefore = this.snapshotGeneList()
    }
    this._geneListHistoryBatchDepth += 1
  }

  endGeneListHistoryBatch() {
    if (this._geneListHistoryBatchDepth <= 0) return
    this._geneListHistoryBatchDepth -= 1
    if (this._geneListHistoryBatchDepth > 0) return

    const before = this._geneListHistoryBefore
    this._geneListHistoryBefore = null
    if (this._skipGeneListHistoryRecord) {
      this.updateGeneListHistoryControls()
      return
    }
    if (!before) {
      this.updateGeneListHistoryControls()
      return
    }
    const beforeKey = this.geneListHistoryKey(before)
    const afterKey = this.geneListHistoryKey(this.geneTags)
    if (beforeKey === afterKey) {
      this.updateGeneListHistoryControls()
      return
    }
    this.pushGeneListHistoryEntry(before)
    this.updateGeneListHistoryControls()
  }

  pushGeneListHistoryEntry(snapshot) {
    if (!Array.isArray(this.geneListHistory)) this.geneListHistory = []
    const genes = Array.isArray(snapshot) ? snapshot.map((gene) => ({ ...gene })) : []
    this.geneListHistory.unshift({
      genes,
      label: this.geneListHistoryLabel(genes)
    })
    if (this.geneListHistory.length > 10) {
      this.geneListHistory = this.geneListHistory.slice(0, 10)
    }
  }

  updateGeneListHistoryControls() {
    const revertBtn = document.getElementById('gene-list-revert-btn')
    const historyBtn = document.getElementById('gene-list-history-btn')
    const historyCount = Array.isArray(this.geneListHistory) ? this.geneListHistory.length : 0
    const showControls = historyCount > 0

    if (revertBtn) {
      revertBtn.style.display = showControls ? 'inline-flex' : 'none'
      revertBtn.disabled = !showControls
    }
    if (historyBtn) {
      historyBtn.style.display = showControls ? 'inline-flex' : 'none'
      historyBtn.disabled = !showControls
      historyBtn.title = showControls
        ? `Gene list history (${historyCount})`
        : 'Gene list history'
    }
    if (!showControls) this.closeGeneListHistoryMenu()
  }

  closeGeneListHistoryMenu() {
    const menu = document.getElementById('gene-list-history-menu')
    if (menu) menu.style.display = 'none'
  }

  toggleGeneListHistoryMenu(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const menu = document.getElementById('gene-list-history-menu')
    if (!menu) return
    const isOpen = menu.style.display === 'block'
    if (typeof this.controller?.closeAllDropdowns === 'function') {
      this.controller.closeAllDropdowns()
    } else {
      this.closeGeneListHistoryMenu()
    }
    if (isOpen) return
    this.renderGeneListHistoryMenu()
    menu.style.display = 'block'
  }

  renderGeneListHistoryMenu() {
    const menu = document.getElementById('gene-list-history-menu')
    if (!menu) return
    menu.innerHTML = ''
    const entries = Array.isArray(this.geneListHistory) ? this.geneListHistory : []
    if (entries.length === 0) {
      const empty = document.createElement('div')
      empty.style.cssText = 'padding: 10px 12px; font-size: 12px; color: #6b7280;'
      empty.textContent = 'No previous gene lists'
      menu.appendChild(empty)
      return
    }

    entries.forEach((entry, index) => {
      const button = document.createElement('button')
      button.type = 'button'
      button.dataset.historyIndex = String(index)
      button.style.cssText = 'display: block; width: 100%; text-align: left; padding: 8px 12px; border: none; background: none; cursor: pointer; font-size: 12px; color: #374151; border-bottom: 1px solid #f3f4f6;'
      const label = entry.label || this.geneListHistoryLabel(entry.genes)
      button.textContent = label
      button.title = label
      button.addEventListener('mouseenter', () => { button.style.backgroundColor = '#f3f4f6' })
      button.addEventListener('mouseleave', () => { button.style.backgroundColor = '' })
      button.addEventListener('click', (event) => this.applyGeneListHistoryEntry(event))
      menu.appendChild(button)
    })
  }

  async revertToPreviousGeneList() {
    this.closeGeneListHistoryMenu()
    if (!Array.isArray(this.geneListHistory) || this.geneListHistory.length === 0) return
    const previous = this.geneListHistory.shift()
    this.updateGeneListHistoryControls()
    await this.applyGeneListSnapshot(previous?.genes || [])
  }

  async applyGeneListHistoryEntry(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const button = event?.currentTarget
    const index = parseInt(button?.dataset?.historyIndex, 10)
    if (!Number.isInteger(index) || index < 0 || !Array.isArray(this.geneListHistory)) return
    if (index >= this.geneListHistory.length) return
    const [entry] = this.geneListHistory.splice(index, 1)
    this.closeGeneListHistoryMenu()
    this.updateGeneListHistoryControls()
    await this.applyGeneListSnapshot(entry?.genes || [])
  }

  async applyGeneListSnapshot(geneEntries) {
    const normalizedGenes = (Array.isArray(geneEntries) ? geneEntries : []).map((gene) => ({ ...gene }))
    this.beginGeneListHistoryBatch()
    try {
      const nextGeneStableIds = normalizedGenes.map((gene) => String(gene.stableId || '')).filter((id) => id.length > 0)
      this.syncGeneExpressionFilterStateForGenes(nextGeneStableIds)
      this.geneTags = normalizedGenes
      this.notFoundQueries = []
      this.updateGeneCountBadge()
      await this.processAllGenes()
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  scheduleAutocompleteLoadRetry() {
    if (this.autocompleteLoaded || this.autocompleteLoadRetryTimer) return
    this.autocompleteLoadRetryTimer = setTimeout(() => {
      this.autocompleteLoadRetryTimer = null
      if (!this.autocompleteLoaded) {
        this.loadAutocompleteData()
      }
    }, 250)
  }

  resolveCurrentLoomFile() {
    const controller = this.resolveVisualizationController()
    if (controller && typeof controller.getCurrentLoomFileForRequest === 'function') {
      const loom = controller.getCurrentLoomFileForRequest()
      if (loom) return loom
    }
    if (controller?.currentLoomFile) return controller.currentLoomFile

    const linkLoom = document.getElementById('embedding-selection-link')?.dataset?.currentLoomFile
    if (linkLoom) return linkLoom

    const select = document.querySelector('[data-visualization-target="loomFileSelect"]')
    if (select?.value) return select.value

    return null
  }

  async loadAutocompleteData() {
    if (!this.projectIdentifier) {
      console.warn('GeneManager: No project identifier found')
      return
    }

    const loomFile = this.resolveCurrentLoomFile()
    if (!loomFile) {
      console.warn('[GeneManager] loadAutocompleteData deferred: loom file is not selected yet')
      this.scheduleAutocompleteLoadRetry()
      return
    }

    try {
      const url = `/projects/${encodeURIComponent(this.projectIdentifier)}/get_autocomplete_genes?loom_file=${encodeURIComponent(loomFile)}`
      const response = await fetch(url, {
        method: 'GET',
        credentials: 'same-origin',
        headers: {
          'Accept': 'application/json'
        }
      })

      let data = null
      if (response.ok) {
        const text = await response.text()
        try {
          data = JSON.parse(text)
        } catch (jsonError) {
          console.warn('GeneManager: Failed to parse generated autocomplete response as JSON:', jsonError)
          console.warn('[GeneManager] Generated response preview:', text.substring(0, 500))
        }
      } else {
        console.warn(`GeneManager: Failed to load autocomplete genes (status ${response.status})`)
      }

      const extractedEntries = this.extractAutocompleteEntries(data)
      this.aliasesByEnsembl = this.extractAliasesByEnsembl(data)
      this.featureNamesByStable = this.extractFeatureNamesByStable(data)
      this.ensemblRelease = data?.ensembl_release != null && data.ensembl_release !== ''
        ? Number(data.ensembl_release)
        : null
      if (extractedEntries.length > 0) {
        this.autocompleteData = extractedEntries
        const geneCount = this.autocompleteData.length
        this.totalGeneCount = geneCount
        console.warn(`[GeneManager] Autocomplete genes loaded: ${geneCount} (loomFile=${loomFile})`)
        // Update the gene count badge
        this.updateGeneCountBadge()
      } else {
        console.warn('GeneManager: Failed to load autocomplete data - data:', data, 'has search:', !!data?.search)
        this.autocompleteData = []
        this.totalGeneCount = 0
        console.warn(`[GeneManager] Autocomplete genes loaded: 0 (loomFile=${loomFile})`)
        this.updateGeneCountBadge()
      }
      this.autocompleteLoaded = true
      this.updateGeneSearchVisibility()
    } catch (error) {
      console.error('GeneManager: Error loading autocomplete data:', error)
      console.error('GeneManager: Error stack:', error.stack)
      this.autocompleteData = []
      this.aliasesByEnsembl = {}
      this.featureNamesByStable = {}
      this.ensemblRelease = null
      this.totalGeneCount = 0
      this.updateGeneCountBadge()
      this.autocompleteLoaded = true
      this.updateGeneSearchVisibility()
    }
  }

  extractAutocompleteEntries(data) {
    if (!data) return []
    if (Array.isArray(data.search)) return data.search
    if (Array.isArray(data)) return data
    return []
  }

  extractFeatureNamesByStable(data) {
    const raw = data && data.feature_names
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {}
    const out = {}
    Object.keys(raw).forEach((stableId) => {
      const key = String(stableId || '').trim()
      const value = String(raw[stableId] || '').trim()
      if (key && value) out[key] = value
    })
    return out
  }

  featureNameForStable(stableId) {
    const key = String(stableId || '').trim()
    if (!key) return ''
    return this.featureNamesByStable[key] || ''
  }

  extractAliasesByEnsembl(data) {
    const raw = data && (data.aliases || data.aliases_by_ensembl)
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {}

    const out = {}
    Object.keys(raw).forEach((ensemblId) => {
      const entry = raw[ensemblId] || {}
      const key = String(ensemblId || '').trim()
      if (!key) return
      out[key] = {
        alt: Array.isArray(entry.alt) ? entry.alt.map((v) => String(v || '').trim()).filter(Boolean) : [],
        obsolete: Array.isArray(entry.obsolete) ? entry.obsolete.map((v) => String(v || '').trim()).filter(Boolean) : []
      }
      const lower = key.toLowerCase()
      if (!out[lower]) out[lower] = out[key]
    })
    return out
  }

  aliasesForEnsembl(ensemblId) {
    const key = String(ensemblId || '').trim()
    if (!key) return { alt: [], obsolete: [] }
    return this.aliasesByEnsembl[key] || this.aliasesByEnsembl[key.toLowerCase()] || { alt: [], obsolete: [] }
  }

  parseAutocompleteEntry(entry) {
    if (typeof entry !== 'string') return null
    const trimmed = entry.trim()
    if (!trimmed) return null

    // Expected format: "SYMBOL ACCESSION {STABLE_ID}"
    // Older corrupted caches sometimes appended alt-name blobs after Accession:
    // "Ednra ENSMUSG... [AEA001,ET-AR,...] {15976}"
    const braceMatch = trimmed.match(/^(.+)\s+(\S+)\s+\{([^}]+)\}\s*$/)
    if (!braceMatch) return null

    let symbol = braceMatch[1].trim()
    let ensemblId = braceMatch[2].trim()
    const stableId = braceMatch[3].trim()
    if (!symbol || !ensemblId || !stableId) return null

    const ensemblTokenRe = /^(?:ENS[A-Z]{0,4}G|MGP_[A-Za-z0-9]+_G)\d+(?:\.\d+)?$/i
    if (!ensemblTokenRe.test(ensemblId)) {
      const beforeBrace = trimmed.replace(/\s*\{[^}]+\}\s*$/, '').trim()
      const parts = beforeBrace.split(/\s+/).filter(Boolean)
      const ensIdx = parts.findIndex((part) => ensemblTokenRe.test(part))
      if (ensIdx >= 0) {
        ensemblId = parts[ensIdx].replace(/\.\d+$/, '')
        symbol = parts.slice(0, ensIdx).join(' ').trim() || ensemblId
      }
    } else {
      ensemblId = ensemblId.replace(/\.\d+$/, '')
    }

    return { symbol, ensemblId, stableId, raw: entry }
  }

  isEnsemblLikeId(value) {
    return /^(?:ENS[A-Z]{0,4}G|MGP_[A-Za-z0-9]+_G)\d+(?:\.\d+)?$/i.test(String(value || '').trim())
  }

  resolveGeneIdentity(gene = {}) {
    const stableId = String(gene.stableId || gene.stable_id || '').trim()
    let symbol = String(gene.symbol || gene.name || '').trim()
    let ensemblId = String(gene.ensemblId || gene.ensembl_id || '').trim()

    if (stableId && this.autocompleteData?.length) {
      for (const entry of this.autocompleteData) {
        const parsed = this.parseAutocompleteEntry(entry)
        if (parsed && String(parsed.stableId) === String(stableId)) {
          symbol = parsed.symbol || symbol
          ensemblId = parsed.ensemblId || ensemblId
          break
        }
      }
    }

    if (!this.isEnsemblLikeId(ensemblId)) {
      const fromSymbol = String(symbol).match(/\b((?:ENS[A-Z]{0,4}G|MGP_[A-Za-z0-9]+_G)\d+)(?:\.\d+)?\b/i)
      if (fromSymbol) {
        ensemblId = fromSymbol[1]
        symbol = String(symbol).replace(fromSymbol[0], '').replace(/\s+/g, ' ').trim() || symbol
      }
    } else {
      ensemblId = ensemblId.replace(/\.\d+$/, '')
    }

    return { symbol, ensemblId, stableId }
  }

  // Rank: latest name (0-2) < ensembl id (3-4) < alt (5-6) < obsolete (7-8).
  // Within a source, exact < prefix < substring.
  scoreGeneMatch(parsed, searchTerm, searchLower) {
    if (!parsed) return null

    const symbol = String(parsed.symbol || '')
    const ensemblId = String(parsed.ensemblId || '')
    const symbolLower = symbol.toLowerCase()
    const ensemblLower = ensemblId.toLowerCase()

    const scoreText = (text, textLower, base) => {
      if (!text) return null
      if (text === searchTerm) return { rank: base, matchedAlias: text }
      if (textLower === searchLower) return { rank: base + 0.25, matchedAlias: text }
      if (textLower.startsWith(searchLower)) return { rank: base + 0.5, matchedAlias: text }
      if (textLower.includes(searchLower)) return { rank: base + 0.75, matchedAlias: text }
      return null
    }

    let best = scoreText(symbol, symbolLower, 0)
    const ensemblHit = scoreText(ensemblId, ensemblLower, 3)
    if (ensemblHit && (!best || ensemblHit.rank < best.rank)) {
      best = { ...ensemblHit, matchedAlias: null }
    }

    const aliases = this.aliasesForEnsembl(ensemblId)
    for (const alt of aliases.alt) {
      const hit = scoreText(alt, alt.toLowerCase(), 5)
      if (hit && (!best || hit.rank < best.rank)) best = { ...hit, matchSource: 'alt' }
    }
    for (const obsolete of aliases.obsolete) {
      const hit = scoreText(obsolete, obsolete.toLowerCase(), 7)
      if (hit && (!best || hit.rank < best.rank)) best = { ...hit, matchSource: 'obsolete' }
    }

    if (!best) return null
    return {
      ...parsed,
      rank: best.rank,
      matchSource: best.matchSource || 'name',
      matchedAlias: best.matchedAlias && best.matchedAlias !== symbol ? best.matchedAlias : null
    }
  }

  handleInput(query) {
    if (!query || query.trim().length === 0) {
      this.hideDropdown()
      return
    }

    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      console.warn('GeneManager: No autocomplete data available, length:', this.autocompleteData?.length)
      return
    }

    const searchTerm = query.trim()
    const searchLower = searchTerm.toLowerCase()
    const scored = []
    for (const entry of this.autocompleteData) {
      const parsed = this.parseAutocompleteEntry(entry)
      const match = this.scoreGeneMatch(parsed, searchTerm, searchLower)
      if (match) scored.push(match)
    }

    scored.sort((a, b) => {
      if (a.rank !== b.rank) return a.rank - b.rank
      return String(a.symbol).localeCompare(String(b.symbol))
    })

    const seen = new Set()
    this.currentMatches = []
    for (const item of scored) {
      const key = String(item.ensemblId || '').toLowerCase()
      if (!key || seen.has(key)) continue
      seen.add(key)
      this.currentMatches.push(item)
      if (this.currentMatches.length >= 25) break
    }

    if (this.currentMatches.length > 0) {
      this.renderDropdown()
      this.showDropdown()
    } else {
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

    this.currentMatches.forEach((parsed, index) => {
      const { symbol: geneSymbol, ensemblId, stableId, matchedAlias, matchSource } = parsed
      const aliasLine = matchedAlias
        ? `<div style="font-size: 11px; color: #9ca3af; margin-top: 2px;">matched via ${matchSource || 'alias'}: ${matchedAlias}</div>`
        : ''
      const item = document.createElement('div')
      item.style.cssText = 'padding: 10px 12px; cursor: pointer; border-bottom: 1px solid #f3f4f6; transition: background-color 0.15s;'
      item.innerHTML = `
        <div style="font-weight: 500; color: #111827; font-size: 14px;">${geneSymbol}</div>
        <div style="font-size: 12px; color: #6b7280; margin-top: 2px;">${ensemblId} | Stable ID: ${stableId}</div>
        ${aliasLine}
      `
      
      item.addEventListener('mouseenter', () => {
        item.style.backgroundColor = '#f3f4f6'
      })
      item.addEventListener('mouseleave', () => {
        item.style.backgroundColor = 'white'
      })

      item.addEventListener('click', () => {
        this.selectGene(parsed)
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
    const parsed = entry && typeof entry === 'object' && entry.symbol && entry.ensemblId && entry.stableId
      ? entry
      : this.parseAutocompleteEntry(entry)
    if (!parsed) {
      console.error('GeneManager: Invalid gene entry format:', entry)
      return
    }

    const resolved = this.resolveGeneIdentity(parsed)
    const gene = {
      symbol: resolved.symbol || parsed.symbol,
      ensemblId: resolved.ensemblId || parsed.ensemblId,
      stableId: resolved.stableId || parsed.stableId,
      featureName: this.featureNameForStable(resolved.stableId || parsed.stableId),
      query: resolved.symbol || parsed.symbol
    }

    // Add to tags if not already present
    const existingIndex = this.geneTags.findIndex(g => String(g.stableId) === String(gene.stableId))
    if (existingIndex === -1) {
      this.beginGeneListHistoryBatch()
      try {
        this.geneTags.push(gene)
        // Update badge when gene is added
        this.updateGeneCountBadge()
        // Only add the new gene instead of re-rendering all genes
        // This preserves the state of existing genes (filter icons, expansion, etc.)
        const resultsDiv = document.getElementById('gene-expression-results')
        if (resultsDiv) {
          this.displayBulkGene(gene, resultsDiv)
          this._autoColorGeneToken = (this._autoColorGeneToken || 0) + 1
          const autoColorToken = this._autoColorGeneToken
          this.loadGeneExpressionData(gene, resultsDiv)
            .then(() => {
              // Only the latest added gene should drive auto-coloring (bulk-safe).
              if (autoColorToken !== this._autoColorGeneToken) return
              if (typeof this.controller?.applyGeneExpressionColoringForGene === 'function') {
                return this.controller.applyGeneExpressionColoringForGene(gene)
              }
            })
            .catch((error) => {
              console.error('GeneManager: Failed to auto-color newly added gene:', error)
            })
        }
      } finally {
        this.endGeneListHistoryBatch()
      }
    } else if (typeof this.controller?.applyGeneExpressionColoringForGene === 'function') {
      // Gene already listed: still switch plot coloring to this gene's expression
      this._autoColorGeneToken = (this._autoColorGeneToken || 0) + 1
      this.controller.applyGeneExpressionColoringForGene(gene)
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
    if (index < 0 || index >= this.geneTags.length) return
    const geneToRemove = this.geneTags[index]
    if (!geneToRemove) return
    this.removeGeneByStableId(geneToRemove.stableId)
  }

  removeGeneByStableId(stableId) {
    const index = this.geneTags.findIndex(g => String(g.stableId) === String(stableId))
    if (index !== -1) {
      this.beginGeneListHistoryBatch()
      try {
        const metadataKeys = this.getGeneMetadataKeys(stableId, this.currentMatrixAnnotId)
        const metadataIds = [metadataKeys.baseKey, metadataKeys.layerKey]

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
        this.clearGeneMetadataStateForStableIds([stableId])
        const remainingGeneIds = this.geneTags.map((gene) => String(gene.stableId))
        this.syncGeneExpressionFilterStateForGenes(remainingGeneIds)
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
      } finally {
        this.endGeneListHistoryBatch()
      }
    }
  }

  clearAllGenes() {
    if (!Array.isArray(this.geneTags) || this.geneTags.length === 0) return

    this.beginGeneListHistoryBatch()
    try {
      const stableIdsToClear = this.geneTags.map((gene) => String(gene.stableId || '').trim()).filter((id) => id.length > 0)
      const metadataIdsToClear = new Set()
      stableIdsToClear.forEach((stableId) => {
        const metadataKeys = this.getGeneMetadataKeys(stableId, this.currentMatrixAnnotId)
        if (metadataKeys.baseKey) metadataIdsToClear.add(metadataKeys.baseKey)
        if (metadataKeys.layerKey) metadataIdsToClear.add(metadataKeys.layerKey)
      })

      metadataIdsToClear.forEach((metadataId) => {
        if (this.controller?.loadedMetadataVectors && this.controller.loadedMetadataVectors[metadataId]) {
          delete this.controller.loadedMetadataVectors[metadataId]
        }
        if (this.controller?.inlineRangeSliderData && this.controller.inlineRangeSliderData[metadataId]) {
          delete this.controller.inlineRangeSliderData[metadataId]
        }
        if (this.controller?.selectedRanges && this.controller.selectedRanges[metadataId]) {
          delete this.controller.selectedRanges[metadataId]
        }
      })

      this.geneTags = []
      this.notFoundQueries = []
      this.genePanelSavedKey = ''
      this.clearGeneMetadataStateForStableIds(stableIdsToClear)
      this.syncGeneExpressionFilterStateForGenes([])
      this.updateGeneCountBadge()

      const resultsDiv = document.getElementById('gene-expression-results')
      if (resultsDiv) {
        while (resultsDiv.firstChild) {
          resultsDiv.removeChild(resultsDiv.firstChild)
        }
      }

      const summaryDiv = document.getElementById('gene-results-summary')
      if (summaryDiv) {
        summaryDiv.style.display = 'none'
      }
    } finally {
      this.endGeneListHistoryBatch()
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
      const existingIndex = this.geneTags.findIndex(g => String(g.stableId) === String(matched.stableId))
      if (existingIndex === -1) {
        this.beginGeneListHistoryBatch()
        try {
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
        } finally {
          this.endGeneListHistoryBatch()
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
    this.beginGeneListHistoryBatch()
    try {
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
    } finally {
      this.endGeneListHistoryBatch()
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

    const closeId = 'close-gene-input-status-' + Date.now()
    let message = '<div style="display: flex; align-items: center; justify-content: space-between; gap: 8px;">'
    message += '<div style="display: flex; align-items: center; flex-wrap: wrap; gap: 4px;">'
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

    message += '</div>'
    message += `<button type="button" id="${closeId}" style="border: 1px solid #cbd5e1; background: white; color: #475569; border-radius: 4px; width: 22px; height: 22px; line-height: 18px; cursor: pointer; padding: 0;">x</button>`
    message += '</div>'

    statusTextDiv.innerHTML = message

    setTimeout(() => {
      const closeBtn = document.getElementById(closeId)
      if (!closeBtn) return
      closeBtn.addEventListener('click', () => {
        delete statusDiv.dataset.statusType
        statusDiv.style.display = 'none'
        statusTextDiv.innerHTML = ''
      })
    }, 0)
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

  /**
   * Split per-cell expression by discrete/STRING coloring metadata (visible cells only).
   * Categories are sorted by mean expression descending (same idea as legacy Plotly box order).
   */
  buildDiscreteExpressionGroups (expressionValues) {
    const ctrl = this.controller
    if (!ctrl || !expressionValues || expressionValues.length === 0) return null
    const meta = ctrl.colorManager && ctrl.colorManager.getColoringMetadataVector()
    if (!meta || (meta.data_type !== 'DISCRETE' && meta.data_type !== 'STRING')) return null
    const catValues = meta.values
    if (!catValues || catValues.length !== expressionValues.length) return null
    const labels = ctrl.dataManager.getCategoryLabels(meta)
    if (!labels) {
      throw new Error(`Discrete metadata ${meta.id} is missing compression_info.categories`)
    }

    const filteredIndices = ctrl.dataManager && ctrl.dataManager.getIncrementalFilteredIndices()
    const visibleSet = filteredIndices ? new Set(filteredIndices) : null

    const map = new Map()
    for (let i = 0; i < expressionValues.length; i++) {
      if (visibleSet && !visibleSet.has(i)) continue
      const label = labels[catValues[i]]
      const key = label === null || label === undefined ? '' : String(label)
      if (!map.has(key)) map.set(key, [])
      map.get(key).push(expressionValues[i])
    }

    const groups = []
    map.forEach((values, name) => {
      const finite = values.filter(v => Number.isFinite(Number(v)))
      const mean = finite.length ? finite.reduce((a, b) => a + b, 0) / finite.length : 0
      groups.push({ name, values, mean })
    })
    groups.sort((a, b) => b.mean - a.mean)
    return groups.map(({ name, values }) => ({ name, values }))
  }

  /**
   * Whether a cell's metadata value (category code) matches the annotation popup category.
   */
  cellMatchesAnnotCategory (metaVal, catName, catIdx, metaVector) {
    if (metaVal === null || metaVal === undefined) return false
    const dm = this.controller?.dataManager
    if (!dm || !metaVector || !dm.isDiscreteMetadata(metaVector)) return false
    const code = Number(metaVal)
    if (!Number.isFinite(code)) return false
    if (catIdx != null && catIdx !== '') {
      const idx = parseInt(catIdx, 10)
      if (!Number.isNaN(idx) && code === idx) return true
    }
    if (catName != null && String(catName).trim() !== '') {
      const expected = dm.labelToCode(metaVector, catName)
      if (expected >= 0 && code === expected) return true
    }
    return false
  }

  /**
   * Split expression into cells in the given category vs all other visible cells (same metadata column as annotations).
   */
  splitExpressionByAnnotCategory (expressionValues, metadataVector, catName, catIdx, visibleSet) {
    if (!this.controller || !metadataVector || !expressionValues || expressionValues.length === 0) return null
    const dt = metadataVector.data_type
    if (dt !== 'DISCRETE' && dt !== 'STRING') return null
    const mv = metadataVector.values
    if (!mv || mv.length !== expressionValues.length) return null

    const inCategory = []
    const rest = []
    for (let i = 0; i < expressionValues.length; i++) {
      if (visibleSet && !visibleSet.has(i)) continue
      const num = Number(expressionValues[i])
      if (!Number.isFinite(num)) continue
      if (this.cellMatchesAnnotCategory(mv[i], catName, catIdx, metadataVector)) {
        inCategory.push(num)
      } else {
        rest.push(num)
      }
    }
    return { inCategory, rest }
  }

  updateGeneCategoryBoxplot (stableId) {
    const idStr = String(stableId)
    const geneDiv = document.querySelector(`[data-gene-item="${idStr}"]`)
    if (!geneDiv) return
    const section = geneDiv.querySelector('.gene-category-boxplot-section')
    const webgl = geneDiv.querySelector('.gene-category-boxplot-webgl')
    const labels = geneDiv.querySelector('.gene-category-boxplot-labels')
    if (!section || !webgl || !labels) return

    const expr = this.geneExpressionData[idStr] ||
      this.geneExpressionData[stableId] ||
      this.geneExpressionData[parseInt(idStr, 10)]
    if (!expr || !expr.values) {
      section.style.display = 'none'
      renderGeneCategoryBoxplot(webgl, labels, [], {})
      return
    }

    const groups = this.buildDiscreteExpressionGroups(expr.values)
    if (!groups || groups.length === 0) {
      section.style.display = 'none'
      renderGeneCategoryBoxplot(webgl, labels, [], {})
      return
    }

    section.style.display = 'block'
    requestAnimationFrame(() => {
      renderGeneCategoryBoxplot(webgl, labels, groups, { yAxisLabel: 'Expression' })
    })
  }

  refreshGeneCategoryBoxplots () {
    document.querySelectorAll('[data-gene-item]').forEach((el) => {
      const id = el.getAttribute('data-gene-item')
      if (id) this.updateGeneCategoryBoxplot(id)
    })
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

    const searchTerm = query.trim()
    if (!searchTerm) return null
    const searchLower = searchTerm.toLowerCase()

    let best = null
    for (const entry of this.autocompleteData) {
      const parsed = this.parseAutocompleteEntry(entry)
      const match = this.scoreGeneMatch(parsed, searchTerm, searchLower)
      if (!match) continue
      if (!best || match.rank < best.rank) best = match
    }

    if (!best) return null
    return {
      symbol: best.symbol,
      ensemblId: best.ensemblId,
      stableId: best.stableId,
      featureName: this.featureNameForStable(best.stableId),
      originalQuery: query,
      matchSource: best.matchSource,
      matchedAlias: best.matchedAlias
    }
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
        
        <!-- Gene Info Button -->
        <button class="gene-info-btn"
                data-gene-id="${gene.stableId}"
                data-gene-symbol="${gene.symbol}"
                data-ensembl-id="${gene.ensemblId || ''}"
                data-feature-name="${gene.featureName || this.featureNameForStable(gene.stableId) || ''}"
                data-remote-gene-id=""
                style="padding: 4px; color: #9ca3af; background: none; border: none; border-radius: 4px; cursor: pointer; transition: all 0.2s; margin-right: 4px;"
                onmouseover="this.style.color='#6b7280'; this.style.backgroundColor='#f3f4f6';"
                onmouseout="this.style.color='#9ca3af'; this.style.backgroundColor='';"
                title="More gene information"
                onclick="event.stopPropagation(); (function(btn){ var overlay = document.getElementById('annotation-popup-overlay'); var searchUrl = overlay ? overlay.dataset.searchGeneUrl : ''; if (!window.openAnnotationPopupGeneModal || !searchUrl) return; var mgr = (window.visualizationController && window.visualizationController.geneManager) || window.geneManager; var resolved = mgr && typeof mgr.resolveGeneIdentity === 'function' ? mgr.resolveGeneIdentity({ stableId: btn.dataset.geneId || '', symbol: btn.dataset.geneSymbol || '', ensemblId: btn.dataset.ensemblId || '' }) : { symbol: btn.dataset.geneSymbol || '', ensemblId: btn.dataset.ensemblId || '', stableId: btn.dataset.geneId || '' }; var featureName = btn.dataset.featureName || (mgr && typeof mgr.featureNameForStable === 'function' ? mgr.featureNameForStable(resolved.stableId || btn.dataset.geneId || '') : ''); var loomFile = (mgr && typeof mgr.resolveCurrentLoomFile === 'function' ? mgr.resolveCurrentLoomFile() : '') || ''; var ensemblRelease = mgr && mgr.ensemblRelease != null ? mgr.ensemblRelease : ''; window.openAnnotationPopupGeneModal(resolved.ensemblId || '', searchUrl, resolved.symbol || '', btn.dataset.remoteGeneId || '', { featureName: featureName, stableId: resolved.stableId || btn.dataset.geneId || '', loomFile: loomFile, ensemblRelease: ensemblRelease }); })(this);">
          <i class="fas fa-info-circle" style="font-size: 14px;"></i>
        </button>

        <!-- Download Menu -->
        <div class="metadata-download-wrapper" style="position: relative; margin-right: 4px;" onclick="event.stopPropagation()">
          <button class="gene-download-btn"
                  data-action="click->visualization#toggleDownloadMenu"
                  style="padding: 4px; color: #9ca3af; background: none; border: none; border-radius: 4px; cursor: pointer; transition: all 0.2s;"
                  onmouseover="this.style.color='#6b7280'; this.style.backgroundColor='#f3f4f6';"
                  onmouseout="this.style.color='#9ca3af'; this.style.backgroundColor='';"
                  title="Download gene expression">
            <i class="fas fa-file-download" style="font-size: 14px;"></i>
          </button>
          <div class="metadata-download-menu" style="display: none; position: fixed; min-width: 180px; padding: 6px; background-color: white; border: 1px solid #d1d5db; border-radius: 6px; box-shadow: 0 8px 16px rgba(0, 0, 0, 0.12); z-index: 10000;">
            <button type="button"
                    data-gene-id="${gene.stableId}"
                    data-metadata-id="${baseMetadataId}"
                    data-layer-metadata-id="${layerMetadataId}"
                    data-action="click->visualization#downloadGeneExpressionSummary"
                    style="display: block; width: 100%; text-align: left; padding: 8px 10px; border: none; background: none; border-radius: 4px; cursor: pointer; font-size: 12px; color: #374151;"
                    onmouseover="this.style.backgroundColor='#f3f4f6'"
                    onmouseout="this.style.backgroundColor=''">
              Summary (Excel)
            </button>
            <button type="button"
                    data-gene-id="${gene.stableId}"
                    data-metadata-id="${baseMetadataId}"
                    data-layer-metadata-id="${layerMetadataId}"
                    data-action="click->visualization#downloadGeneExpressionRaw"
                    style="display: block; width: 100%; text-align: left; padding: 8px 10px; border: none; background: none; border-radius: 4px; cursor: pointer; font-size: 12px; color: #374151;"
                    onmouseover="this.style.backgroundColor='#f3f4f6'"
                    onmouseout="this.style.backgroundColor=''">
              Raw data (TSV.gz)
            </button>
          </div>
        </div>
        
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
        <div class="metadata-constant-range-notice" style="display: none; font-size: 12px; color: #6b7280; margin-bottom: 8px;">
          All cells have the same value: <span class="metadata-constant-range-value"></span>
        </div>
        <div class="metadata-range-slider-controls">
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
        <div class="gene-category-boxplot-section" style="margin-top: 8px; display: none;">
          <div style="font-size: 12px; font-weight: 600; color: #374151; margin-bottom: 2px;">Gene expression by category</div>
          <div style="font-size: 11px; color: #6b7280; margin-bottom: 6px; line-height: 1.35;">One box per category from the current discrete point coloring (visible cells only). Orange segment: mean; line in box: median.</div>
          <div class="gene-category-boxplot-inner" style="position: relative; width: 100%; height: 220px;">
            <canvas class="gene-category-boxplot-webgl" style="display: block; position: absolute; left: 0; top: 0; width: 100%; height: 100%;"></canvas>
            <canvas class="gene-category-boxplot-labels" style="display: block; position: absolute; left: 0; top: 0; width: 100%; height: 100%; pointer-events: none;"></canvas>
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

    // Expression loading is owned by the caller (processAllGenes / addGene / etc.).
    // Do not start a second concurrent load here — it races with the caller and can
    // overwrite a successful in-memory status with a stale error icon.
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
    if (!this._geneExpressionLoadTokens) this._geneExpressionLoadTokens = {}
    const loadToken = (this._geneExpressionLoadTokens[geneId] = (this._geneExpressionLoadTokens[geneId] || 0) + 1)
    const isCurrentLoad = () => this._geneExpressionLoadTokens[geneId] === loadToken
    
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
    
    if (inMemory && inMemory.values && inMemory.values.length > 0 && inMemory.metadataId === geneMetadataId) {
      // Already in memory for this matrix layer - update status icon
      if (statusIcon) {
        this.controller.uiManager.updateGeneStatusIcon(geneId, 'in-memory')
      }
      if (loadingDiv) {
        loadingDiv.style.display = 'none'
      }
      return
    }

    this.updateGeneCardRangeSliderMetadataIds(gene.stableId, baseMetadataId, geneMetadataId)

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
          this.controller.initializeInlineRangeSlider(
            geneMetadataId,
            expressionData.values,
            this.controller.loadedMetadataVectors?.[geneMetadataId]
          )
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
          this.controller.initializeInlineRangeSlider(
            geneMetadataId,
            expressionValues,
            this.controller.loadedMetadataVectors?.[geneMetadataId]
          )
          if (baseMetadataId !== geneMetadataId && this.controller.inlineRangeSliderData) {
            this.controller.inlineRangeSliderData[baseMetadataId] = this.controller.inlineRangeSliderData[geneMetadataId]
          }
        }
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

      // Ignore stale failures from an older concurrent request for the same gene.
      if (!isCurrentLoad()) return

      // If a newer/parallel request already populated memory, keep the success icon.
      const recovered = this.geneExpressionData[geneId] ||
                        this.geneExpressionData[parseInt(geneId)] ||
                        this.geneExpressionData[String(parseInt(geneId))]
      if (recovered && recovered.values && recovered.values.length > 0 && recovered.metadataId === geneMetadataId) {
        if (this.controller && this.controller.uiManager) {
          this.controller.uiManager.updateGeneStatusIcon(geneId, 'in-memory')
        }
        if (loadingDiv) loadingDiv.style.display = 'none'
        return
      }
      
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

  /**
   * Load expression values for a specific matrix/layer without mutating geneExpressionData or the main UI caches.
   * Used by annotation popup violin plots so a different matrix than the gene panel does not overwrite in-memory state.
   */
  async fetchExpressionForAnnotViolin (gene, layerPath, annotId) {
    const geneId = String(gene.stableId)
    const effectiveLayer = layerPath != null && layerPath !== '' ? String(layerPath) : '/matrix'
    const effectiveAnnotId = annotId != null && String(annotId).trim() !== '' ? String(annotId).trim() : null
    const { baseKey: baseMetadataId, layerKey: geneMetadataId } = this.getGeneMetadataKeys(geneId, effectiveAnnotId)

    const pickMatchingGlobal = () => {
      const candidates = [geneId, parseInt(geneId, 10), String(parseInt(geneId, 10))]
      for (const k of candidates) {
        if (k === undefined || Number.isNaN(k)) continue
        const e = this.geneExpressionData[k]
        if (e && e.values && e.values.length > 0 && e.metadataId === geneMetadataId) {
          return e
        }
      }
      return null
    }

    const fromGlobal = pickMatchingGlobal()
    if (fromGlobal) {
      return {
        values: fromGlobal.values,
        stats: fromGlobal.stats || this.calculateExpressionStats(fromGlobal.values)
      }
    }

    if (this.controller && this.controller.memoryManager) {
      const dbData = await this.controller.memoryManager.loadGeneExpressionFromIndexedDB(geneId, {
        metadataKey: geneMetadataId,
        baseKey: baseMetadataId,
        expectedAnnotId: effectiveAnnotId
      })
      if (dbData && dbData.values && dbData.values.length > 0) {
        return {
          values: dbData.values,
          stats: dbData.stats || this.calculateExpressionStats(dbData.values)
        }
      }
    }

    let loomFile = 'parsing/output.loom'
    try {
      if (this.controller && this.controller.getCurrentLoomFileForRequest) {
        loomFile = this.controller.getCurrentLoomFileForRequest()
      }
    } catch (e) {
      console.warn('GeneManager: Could not get current loom file for annot violin:', e.message)
    }

    if (!this.projectIdentifier) {
      throw new Error('Project identifier is not set')
    }

    let url = `/projects/${encodeURIComponent(this.projectIdentifier)}/gene_expression.json?stable_id=${encodeURIComponent(gene.stableId)}&loom_file=${encodeURIComponent(loomFile)}`
    if (effectiveAnnotId) {
      url += `&annot_id=${encodeURIComponent(effectiveAnnotId)}`
    } else if (effectiveLayer && effectiveLayer !== '/matrix') {
      url += `&layer=${encodeURIComponent(effectiveLayer)}`
    }

    const response = await fetch(url)
    if (!response.ok) {
      const errorData = await response.json().catch(() => ({ error: `HTTP ${response.status}: ${response.statusText}` }))
      const errorMessage = errorData.message ? `${errorData.error}: ${errorData.message}` : (errorData.error || `HTTP ${response.status}`)
      throw new Error(errorMessage)
    }

    const data = await response.json()
    if (data.error) {
      const errorMessage = data.message ? `${data.error}: ${data.message}` : data.error
      throw new Error(errorMessage)
    }
    if (!data.expression_values || data.expression_values.length === 0) {
      throw new Error('No expression values returned from server')
    }

    const expressionValues = data.expression_values
    return {
      values: expressionValues,
      stats: this.calculateExpressionStats(expressionValues)
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
      rangeSection.style.maxHeight = '1400px'
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
            this.updateGeneCategoryBoxplot(geneId)
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
      this.controller.initializeInlineRangeSlider(
        geneMetadataId,
        values,
        this.controller.loadedMetadataVectors?.[geneMetadataId]
      )
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

    this.updateGeneCategoryBoxplot(geneId)
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
      filterSwitch.style.backgroundColor = '#ef4444'
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

  showAddGeneSetCollectionModal() {
    const existingOverlay = document.getElementById('gene-set-collection-modal-overlay')
    if (existingOverlay) existingOverlay.remove()
    const template = document.getElementById('add-gene-set-collection-modal-template')
    if (!template || !template.content || !template.content.firstElementChild) {
      console.error('GeneManager: add gene set collection modal template not found')
      return
    }

    const overlay = template.content.firstElementChild.cloneNode(true)
    const modal = overlay.querySelector('#gene-set-collection-modal-content')
    const form = overlay.querySelector('#add-gene-set-collection-form')
    const nameInput = overlay.querySelector('#gene-set-collection-name-input')
    const emptyCheckbox = overlay.querySelector('#gene-set-collection-empty-checkbox')
    const fileSection = overlay.querySelector('#gene-set-collection-file-section')
    const fileRequiredMark = overlay.querySelector('#gene-set-collection-file-required-mark')
    const fileInput = overlay.querySelector('#gene-set-collection-file-input')
    const dropzone = overlay.querySelector('#gene-set-collection-dropzone')
    const browseBtn = overlay.querySelector('#gene-set-collection-browse-btn')
    const selectedFileEl = overlay.querySelector('#gene-set-collection-selected-file')
    const closeBtn = overlay.querySelector('#close-add-gene-set-collection-modal')
    const cancelBtn = overlay.querySelector('#cancel-add-gene-set-collection-btn')
    const submitBtn = overlay.querySelector('#submit-add-gene-set-collection-btn')
    const feedbackEl = overlay.querySelector('#gene-set-collection-upload-feedback')
    const progressWrapEl = overlay.querySelector('#gene-set-collection-upload-progress-wrap')
    const progressBarEl = overlay.querySelector('#gene-set-collection-upload-progress-bar')
    const progressTextEl = overlay.querySelector('#gene-set-collection-upload-progress-text')
    let selectedCollectionFile = null
    let activeUploadXhr = null

    if (!modal || !form || !nameInput || !fileInput || !submitBtn) {
      console.error('GeneManager: add gene set collection modal elements are missing')
      return
    }

    const isEmptyCollectionMode = () => Boolean(emptyCheckbox?.checked)

    const syncEmptyCollectionMode = () => {
      const emptyMode = isEmptyCollectionMode()
      if (fileSection) fileSection.style.display = emptyMode ? 'none' : 'block'
      if (fileRequiredMark) fileRequiredMark.style.display = emptyMode ? 'none' : 'inline'
      fileInput.required = !emptyMode
      if (emptyMode) {
        selectedCollectionFile = null
        fileInput.value = ''
        updateSelectedFile(null)
        setFeedback('')
        setUploadProgress(0, false)
      }
      if (!submitBtn.disabled) {
        submitBtn.textContent = emptyMode ? 'Create' : 'Upload'
      }
    }

    const setFeedback = (message = '', isError = false) => {
      if (!feedbackEl) return
      const text = String(message || '').trim()
      feedbackEl.textContent = text
      feedbackEl.style.display = text ? 'block' : 'none'
      feedbackEl.style.color = isError ? '#dc2626' : '#1d4ed8'
    }

    const updateSelectedFile = (file) => {
      if (!selectedFileEl) return
      const fileName = file?.name ? String(file.name) : ''
      selectedFileEl.textContent = fileName || 'No file selected'
      selectedFileEl.style.color = fileName ? '#111827' : '#6b7280'
    }

    const isGmtFile = (file) => {
      const name = String(file?.name || '').trim().toLowerCase()
      return name.endsWith('.gmt')
    }

    const setDropzoneActive = (isActive) => {
      if (!dropzone) return
      dropzone.style.borderColor = isActive ? '#2563eb' : '#9ca3af'
      dropzone.style.backgroundColor = isActive ? '#eff6ff' : '#f9fafb'
    }

    const assignFileToInput = (file) => {
      if (!file || !fileInput) return false
      if (!isGmtFile(file)) {
        setFeedback('Only GMT files are allowed.', true)
        return false
      }
      selectedCollectionFile = file
      try {
        const transfer = new DataTransfer()
        transfer.items.add(file)
        fileInput.files = transfer.files
      } catch (error) {
        // Some browsers do not allow setting input.files programmatically.
      }
      updateSelectedFile(file)
      setFeedback('')
      return true
    }

    const setSubmitting = (isSubmitting) => {
      submitBtn.disabled = Boolean(isSubmitting)
      if (isSubmitting) {
        submitBtn.textContent = isEmptyCollectionMode() ? 'Creating...' : 'Uploading...'
        setFeedback('')
        return
      }
      submitBtn.textContent = isEmptyCollectionMode() ? 'Create' : 'Upload'
    }

    const setSubmitButtonLabel = (label) => {
      if (!submitBtn) return
      submitBtn.textContent = String(label || '').trim() || (isEmptyCollectionMode() ? 'Create' : 'Upload')
    }

    const setUploadProgress = (percent, visible = true) => {
      const normalized = Math.max(0, Math.min(100, Math.round(Number(percent) || 0)))
      if (progressWrapEl) progressWrapEl.style.display = visible ? 'block' : 'none'
      if (progressBarEl) progressBarEl.style.width = `${normalized}%`
      if (progressTextEl) progressTextEl.textContent = `${normalized}%`
    }

    const upsertCreatedCollection = (collection) => {
      if (!collection) return
      const collectionsController = this.controller?.geneSetCollectionsController
      if (collectionsController && typeof collectionsController.upsertCollectionFromPayload === 'function') {
        collectionsController.upsertCollectionFromPayload(collection)
      }
      const collectionId = String(collection.id || '').trim()
      const label = String(collection.label || '').trim()
      if (!collectionId || !label) return
      if (String(collection.type_key || '').trim() !== 'manual') return

      const modalTemplate = document.getElementById('save-manual-gene-set-modal-template')
      const select = modalTemplate?.content?.querySelector('#gene-set-collection-select')
      if (!select) return
      let option = Array.from(select.options || []).find((entry) => String(entry.value || '').trim() === collectionId)
      if (!option) {
        option = document.createElement('option')
        option.value = collectionId
        const createOption = Array.from(select.options || []).find(
          (entry) => String(entry.value || '').trim() === '__new_manual_collection__'
        )
        if (createOption) {
          select.insertBefore(option, createOption)
        } else {
          select.appendChild(option)
        }
      }
      option.textContent = label
    }

    const uploadGeneSetCollectionWithProgress = ({ projectIdentifier, csrfToken, formData, onProgress }) => (
      new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest()
        activeUploadXhr = xhr
        xhr.open('POST', `/projects/${encodeURIComponent(projectIdentifier)}/import_gene_set_collection`, true)
        xhr.withCredentials = true
        xhr.timeout = 180000
        xhr.setRequestHeader('Accept', 'application/json')
        if (csrfToken) xhr.setRequestHeader('X-CSRF-Token', csrfToken)

        const cleanupXhrReference = () => {
          if (activeUploadXhr === xhr) activeUploadXhr = null
        }

        xhr.upload.addEventListener('progress', (event) => {
          if (!event.lengthComputable) return
          const percent = Math.round((event.loaded / event.total) * 100)
          if (typeof onProgress === 'function') onProgress(percent)
        })

        xhr.addEventListener('load', () => {
          cleanupXhrReference()
          let payload = null
          try {
            payload = JSON.parse(xhr.responseText || '{}')
          } catch (error) {
            reject(new Error('Invalid server response during upload'))
            return
          }
          if (xhr.status < 200 || xhr.status >= 300 || !['ok', 'queued'].includes(payload.status)) {
            reject(new Error(payload.message || 'Failed to import gene set collection'))
            return
          }
          resolve(payload)
        })

        xhr.addEventListener('error', () => {
          cleanupXhrReference()
          reject(new Error('Upload failed due to a network error'))
        })
        xhr.addEventListener('abort', () => {
          cleanupXhrReference()
          reject(new Error('Upload was cancelled'))
        })
        xhr.addEventListener('timeout', () => {
          cleanupXhrReference()
          reject(new Error('Upload request timed out while processing'))
        })
        xhr.send(formData)
      })
    )

    const createEmptyGeneSetCollection = async ({ projectIdentifier, csrfToken, collectionName }) => {
      const headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
      if (csrfToken) headers['X-CSRF-Token'] = csrfToken
      const response = await fetch(`/projects/${encodeURIComponent(projectIdentifier)}/import_gene_set_collection`, {
        method: 'POST',
        credentials: 'same-origin',
        headers,
        body: JSON.stringify({
          name: collectionName,
          empty: true
        })
      })
      const payload = await response.json()
      if (!response.ok || payload.status !== 'ok') {
        throw new Error(payload.message || 'Failed to create gene set collection')
      }
      return payload
    }

    const closeModal = () => {
      if (activeUploadXhr) {
        activeUploadXhr.abort()
      }
      const current = document.getElementById('gene-set-collection-modal-overlay')
      if (current) current.remove()
    }

    document.body.appendChild(overlay)
    syncEmptyCollectionMode()

    if (emptyCheckbox) {
      emptyCheckbox.addEventListener('change', () => {
        syncEmptyCollectionMode()
      })
    }

    if (closeBtn) {
      closeBtn.addEventListener('click', (event) => {
        event.preventDefault()
        event.stopPropagation()
        closeModal()
      })
    }

    if (cancelBtn) {
      cancelBtn.addEventListener('click', (event) => {
        event.preventDefault()
        event.stopPropagation()
        closeModal()
      })
    }

    overlay.addEventListener('click', (event) => {
      if (event.target === overlay) closeModal()
    })

    modal.addEventListener('click', (event) => {
      event.stopPropagation()
    })

    if (browseBtn) {
      browseBtn.addEventListener('click', (event) => {
        event.preventDefault()
        event.stopPropagation()
        fileInput.click()
      })
    }

    if (dropzone) {
      dropzone.addEventListener('click', () => {
        fileInput.click()
      })
      ;['dragenter', 'dragover'].forEach((eventName) => {
        dropzone.addEventListener(eventName, (event) => {
          event.preventDefault()
          event.stopPropagation()
          setDropzoneActive(true)
        })
      })
      ;['dragleave', 'drop'].forEach((eventName) => {
        dropzone.addEventListener(eventName, (event) => {
          event.preventDefault()
          event.stopPropagation()
          setDropzoneActive(false)
        })
      })
      dropzone.addEventListener('drop', (event) => {
        const droppedFile = event.dataTransfer?.files?.[0]
        if (!droppedFile) return
        assignFileToInput(droppedFile)
      })
    }

    fileInput.addEventListener('change', () => {
      const selectedFile = fileInput.files && fileInput.files[0]
      if (!selectedFile) {
        selectedCollectionFile = null
        updateSelectedFile(null)
        return
      }
      if (!isGmtFile(selectedFile)) {
        fileInput.value = ''
        selectedCollectionFile = null
        updateSelectedFile(null)
        setFeedback('Only GMT files are allowed.', true)
        return
      }
      selectedCollectionFile = selectedFile
      updateSelectedFile(selectedFile)
      setFeedback('')
    })

    form.addEventListener('submit', async (event) => {
      event.preventDefault()
      event.stopPropagation()
      setFeedback('')

      const collectionName = String(nameInput.value || '').trim()
      if (!collectionName) {
        setFeedback('Please enter a collection name.', true)
        nameInput.focus()
        return
      }

      const projectIdentifier = this.controller?.getProjectIdentifier?.() || this.projectIdentifier
      if (!projectIdentifier) {
        setFeedback('Project context is missing.', true)
        return
      }

      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
      const emptyMode = isEmptyCollectionMode()

      if (emptyMode) {
        setSubmitting(true)
        try {
          const payload = await createEmptyGeneSetCollection({
            projectIdentifier,
            csrfToken,
            collectionName
          })
          upsertCreatedCollection(payload.collection)
          if (this.controller && typeof this.controller.setSelectionTab === 'function') {
            this.controller.setSelectionTab('gene-sets')
          }
          closeModal()
        } catch (error) {
          setFeedback(error.message || 'Failed to create gene set collection', true)
        } finally {
          setSubmitting(false)
        }
        return
      }

      const file = selectedCollectionFile || (fileInput.files && fileInput.files[0])
      if (!file) {
        setFeedback('Please choose a GMT file to upload.', true)
        return
      }
      if (!isGmtFile(file)) {
        setFeedback('Only GMT files are allowed.', true)
        return
      }

      const currentLoomFile = this.controller?.getCurrentLoomFileForRequest?.() || this.controller?.currentLoomFile || ''
      if (!currentLoomFile) {
        setFeedback('Loom file context is missing.', true)
        return
      }
      const formData = new FormData()
      formData.append('name', collectionName)
      formData.append('file', file)
      formData.append('loom_file', currentLoomFile)

      setSubmitting(true)
      setUploadProgress(0, true)
      try {
        const payload = await uploadGeneSetCollectionWithProgress({
          projectIdentifier,
          csrfToken,
          formData,
          onProgress: (percent) => {
            setUploadProgress(percent, true)
            if (percent >= 100) {
              setSubmitButtonLabel('Processing...')
            }
          }
        })
        setUploadProgress(100, true)

        if (payload.status === 'queued') {
          const importId = String(payload.import_id || '').trim()
          if (importId) this.pendingCollectionImportIds.add(importId)
          if (payload.collection) {
            upsertCreatedCollection(payload.collection)
            this.startCollectionImportPolling(String(payload.collection.id || ''))
          }
          if (this.controller && typeof this.controller.setSelectionTab === 'function') {
            this.controller.setSelectionTab('gene-sets')
          }
          closeModal()
          return
        }

        upsertCreatedCollection(payload.collection)
        closeModal()
      } catch (error) {
        setFeedback(error.message || 'Failed to import gene set collection', true)
      } finally {
        if (progressWrapEl && progressWrapEl.style.display !== 'none') {
          setTimeout(() => setUploadProgress(0, false), 250)
        } else {
          setUploadProgress(0, false)
        }
        setSubmitting(false)
      }
    })

    setTimeout(() => {
      nameInput.focus()
    }, 100)
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

    const template = document.getElementById('save-manual-gene-set-modal-template')
    if (!template || !template.content || !template.content.firstElementChild) {
      console.error('GeneManager: save manual gene set modal template not found')
      return
    }
    const overlay = template.content.firstElementChild.cloneNode(true)
    const modal = overlay.querySelector('#gene-set-modal-content')
    if (!modal) {
      console.error('GeneManager: modal content missing in template')
      return
    }

    const collectionSelect = overlay.querySelector('#gene-set-collection-select')
    const collectionSelectWrap = overlay.querySelector('#gene-set-collection-select-wrap')
    const newCollectionWrap = overlay.querySelector('#gene-set-new-collection-wrap')
    const newCollectionInput = overlay.querySelector('#gene-set-new-collection-input')
    const newCollectionValue = '__new_manual_collection__'
    const defaultNewCollectionLabel = 'Manual Gene Sets'

    const manualRows = Array.from(document.querySelectorAll('[data-gene-set-collection-row="true"]'))
      .filter((row) => String(row.dataset.collectionTypeKey || '').trim() === 'manual')
      .map((row) => ({
        id: String(row.dataset.collectionId || '').trim(),
        label: String(row.dataset.collectionLabel || '').trim()
      }))
      .filter((entry) => entry.id && entry.label)

    const syncNewCollectionVisibility = () => {
      const hasExisting = manualRows.length > 0
      const isNew = !hasExisting || (collectionSelect && collectionSelect.value === newCollectionValue)
      if (collectionSelectWrap) {
        collectionSelectWrap.style.display = hasExisting ? '' : 'none'
      }
      if (newCollectionWrap) {
        newCollectionWrap.style.display = isNew ? 'block' : 'none'
        newCollectionWrap.style.marginTop = hasExisting && isNew ? '10px' : '0'
      }
      if (isNew && newCollectionInput && !String(newCollectionInput.value || '').trim()) {
        newCollectionInput.value = defaultNewCollectionLabel
      }
    }

    if (collectionSelect) {
      const createOpt = collectionSelect.querySelector(`option[value="${newCollectionValue}"]`)
      collectionSelect.innerHTML = ''
      manualRows.forEach((entry) => {
        const option = document.createElement('option')
        option.value = entry.id
        option.textContent = entry.label
        collectionSelect.appendChild(option)
      })
      if (createOpt) {
        collectionSelect.appendChild(createOpt)
      } else {
        const option = document.createElement('option')
        option.value = newCollectionValue
        option.textContent = 'Create new collection...'
        collectionSelect.appendChild(option)
      }
      if (manualRows.length > 0) {
        collectionSelect.value = manualRows[0].id
      } else {
        collectionSelect.value = newCollectionValue
      }
      collectionSelect.addEventListener('change', syncNewCollectionVisibility)
    }
    syncNewCollectionVisibility()

    const escapeHtml = (value) => String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')

    const genesCountEl = overlay.querySelector('#gene-set-genes-count')
    const genesTableBody = overlay.querySelector('#gene-set-genes-table-body')
    if (genesTableBody) {
      genesTableBody.innerHTML = genes.map((gene, index) => {
        const rowBg = index % 2 === 0 ? '#ffffff' : '#f9fafb'
        const symbol = escapeHtml(gene?.symbol)
        const ensemblId = escapeHtml(gene?.ensemblId || gene?.ensembl_id)
        const stableId = escapeHtml(gene?.stableId || gene?.stable_id)
        return `
          <tr style="border-bottom:1px solid #f3f4f6;background-color:${rowBg};">
            <td style="padding:12px;text-align:center;">
              <input
                type="checkbox"
                class="gene-set-gene-checkbox"
                checked
                data-symbol="${symbol}"
                data-ensembl-id="${ensemblId}"
                data-stable-id="${stableId}"
                style="width:14px;height:14px;cursor:pointer;"
              />
            </td>
            <td style="padding:12px;font-size:13px;color:#111827;">${symbol}</td>
            <td style="padding:12px;font-size:13px;color:#6b7280;font-family:monospace;">${ensemblId}</td>
            <td style="padding:12px;font-size:13px;color:#6b7280;font-family:monospace;">${stableId}</td>
          </tr>
        `
      }).join('')
    }

    const updateSelectedGenesCount = () => {
      const checkedCount = overlay.querySelectorAll('.gene-set-gene-checkbox:checked').length
      if (genesCountEl) genesCountEl.textContent = String(checkedCount)
      const selectAllCheckbox = overlay.querySelector('#gene-set-select-all-checkbox')
      const allCheckboxes = overlay.querySelectorAll('.gene-set-gene-checkbox')
      if (selectAllCheckbox && allCheckboxes.length > 0) {
        selectAllCheckbox.checked = checkedCount === allCheckboxes.length
        selectAllCheckbox.indeterminate = checkedCount > 0 && checkedCount < allCheckboxes.length
      }
    }
    updateSelectedGenesCount()

    document.body.appendChild(overlay)

    const selectAllCheckbox = overlay.querySelector('#gene-set-select-all-checkbox')
    if (selectAllCheckbox) {
      selectAllCheckbox.addEventListener('change', () => {
        overlay.querySelectorAll('.gene-set-gene-checkbox').forEach((checkbox) => {
          checkbox.checked = selectAllCheckbox.checked
        })
        updateSelectedGenesCount()
      })
    }
    overlay.querySelectorAll('.gene-set-gene-checkbox').forEach((checkbox) => {
      checkbox.addEventListener('change', updateSelectedGenesCount)
    })
    
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
    document.getElementById('add-gene-set-form').addEventListener('submit', async (e) => {
      e.preventDefault()
      const nameInput = document.getElementById('gene-set-name-input')
      const liveCollectionSelect = document.getElementById('gene-set-collection-select')
      const liveNewCollectionInput = document.getElementById('gene-set-new-collection-input')
      const geneSetName = nameInput.value.trim()
      const hasExistingCollections = manualRows.length > 0
      const targetCollectionId = hasExistingCollections
        ? String(liveCollectionSelect?.value || '').trim()
        : newCollectionValue
      let newCollectionName = ''

      if (!geneSetName) {
        alert('Please enter a gene set name.')
        nameInput.focus()
        return
      }
      if (!targetCollectionId) {
        alert('Please select a gene set collection.')
        if (liveCollectionSelect) liveCollectionSelect.focus()
        return
      }
      if (targetCollectionId === newCollectionValue) {
        newCollectionName = String(liveNewCollectionInput?.value || '').trim()
        if (!newCollectionName) {
          alert('Please enter a name for the new collection.')
          if (liveNewCollectionInput) liveNewCollectionInput.focus()
          return
        }
      }
      
      const checkedCheckboxes = Array.from(
        document.querySelectorAll('#gene-set-genes-table-body .gene-set-gene-checkbox:checked')
      )
      if (checkedCheckboxes.length === 0) {
        alert('Please select at least one gene.')
        return
      }

      const normalizedGenes = checkedCheckboxes.map((checkbox) => ({
        symbol: String(checkbox.dataset.symbol || '').trim(),
        ensembl_id: String(checkbox.dataset.ensemblId || '').trim(),
        stable_id: String(checkbox.dataset.stableId || '').trim()
      }))

      const projectIdentifier = this.controller?.getProjectIdentifier?.() || this.projectIdentifier
      if (!projectIdentifier) {
        alert('Project context is missing.')
        return
      }

      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
      const isCreatingNewCollection = targetCollectionId === newCollectionValue
      let collectionLabel = newCollectionName
      if (!isCreatingNewCollection && liveCollectionSelect) {
        const selectedOption = liveCollectionSelect.options?.[liveCollectionSelect.selectedIndex]
        collectionLabel = String(selectedOption?.textContent || '').trim()
      }

      const collectionsController = this.controller?.geneSetCollectionsController
      const pendingState = collectionsController && typeof collectionsController.beginPendingGeneSetSave === 'function'
        ? collectionsController.beginPendingGeneSetSave({
          collectionId: isCreatingNewCollection ? null : targetCollectionId,
          collectionLabel,
          isNewCollection: isCreatingNewCollection,
          typeKey: 'manual',
          geneSetName,
          geneCount: normalizedGenes.length
        })
        : null

      closeModal()

      try {
        const headers = {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        }
        if (csrfToken) headers['X-CSRF-Token'] = csrfToken

        const body = {
          name: geneSetName,
          genes: normalizedGenes,
          collection_id: targetCollectionId
        }
        if (newCollectionName) body.new_collection_name = newCollectionName

        const response = await fetch(`/projects/${encodeURIComponent(projectIdentifier)}/save_manual_gene_set`, {
          method: 'POST',
          credentials: 'same-origin',
          headers,
          body: JSON.stringify(body)
        })
        const payload = await response.json()
        if (!response.ok || payload.status !== 'ok') {
          throw new Error(payload.message || 'Failed to save manual gene set')
        }

        if (pendingState && typeof collectionsController.completePendingGeneSetSave === 'function') {
          await collectionsController.completePendingGeneSetSave(pendingState, payload)
        } else if (collectionsController && typeof collectionsController.upsertCollectionFromPayload === 'function') {
          collectionsController.upsertCollectionFromPayload(payload.collection)
        }
        this.markGenePanelContentSaved()
      } catch (error) {
        if (pendingState && typeof collectionsController?.failPendingGeneSetSave === 'function') {
          collectionsController.failPendingGeneSetSave(pendingState)
        }
        alert(error.message || 'Failed to save manual gene set')
      }
    })
    
    // Focus on name input
    setTimeout(() => {
      document.getElementById('gene-set-name-input').focus()
    }, 100)
  }

}

