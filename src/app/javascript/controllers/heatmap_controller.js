import { Controller } from "@hotwired/stimulus"
import { ReglHeatmap } from "visualization/regl_heatmap"
import { GradientManager } from "visualization/gradient_manager"
import { ColorManager } from "visualization/color_manager"
import { DataManager } from "visualization/data_manager"
import { GeneSetCollectionsController } from "visualization/gene_set_collections_controller"
import { GeneSetOverlapPopup } from "visualization/gene_set_overlap_popup"
import { canvasToJpegThumbnailDataUrl, isCheckpointThumbnailDataUrl } from "lib/checkpoint_thumbnail"
import { DEFAULT_NAN_COLOR_INT, nanColorToHex, parseNanColor } from "lib/nan_color"
import consumer from "channels/consumer"

// Interactive expression heatmap viewer.
//
// Renders the precomputed genes x columns matrix (WebGL) with a Canvas 2D
// overlay for row/column dendrograms, categorical/numerical annotation tracks,
// axis labels and a colormap legend. Supports Shift+scroll zoom, drag pan,
// rectangular gene/cell selection, and reset. Clicking the colormap or
// continuous-track legends opens the shared gradient editor modal.
export default class extends Controller {
  static values = {
    projectKey: String,
    projectId: String,
    runId: String,
    runNum: String,
    runLabel: String,
    dataUrl: String,
    searchGeneUrl: String,
    canAnalyze: { type: Boolean, default: false },
    canEdit: { type: Boolean, default: false },
    currentUserId: { type: Number, default: 0 }
  }

  static targets = [
    "webgl", "overlay", "status", "statusSpinner", "statusMessage", "tooltip",
    "colTrackList", "rowTrackList", "colTrackListEmpty", "rowTrackListEmpty",
    "addColTrackBtn", "addRowTrackBtn",
    "trackModal", "trackModalTitle", "trackModalSelect",
    "trackModalSize", "trackModalShowLegend", "trackModalLegendWrap", "trackModalHint",
    "trackModalSourceWrap", "trackModalSource", "trackModalMetadataWrap",
    "trackModalGeneSetWrap", "trackModalGeneSetSearch", "trackModalGeneSetSearchResults",
    "editTrackModal", "editTrackModalTitle", "editTrackModalName",
    "editTrackType", "editTrackTypeWrap", "editTrackTypeHint",
    "editTrackDisplayMode", "editTrackDisplayModeWrap",
    "editTrackSize", "editTrackShowLegend", "editTrackLegendWrap", "editTrackGradientBtn",
    "colTreeToggle", "rowTreeToggle", "labelsToggle",
    "colTreeState", "rowTreeState", "labelsState",
    "settingsBtn", "settingsMenu", "legendWidthSlider", "legendWidthValue",
    "rightMarginSlider", "rightMarginValue",
    "checkpointHistoryOverlay", "checkpointHistoryList", "checkpointHistoryLoading", "checkpointHistoryBtn",
    "checkpointCommentsOverlay", "checkpointCommentsTitle", "checkpointCommentsList",
    "checkpointCommentSelect", "checkpointCommentInput", "checkpointCommentsBtn",
    "checkpointLoadingOverlay", "checkpointLoadingMessage",
    "panModeBtn", "selectModeBtn", "controlInstructions",
    "selectedGenesCount", "selectedCellsCount",
    "savedCellSetsList",
    "geneSelectionStatus", "cellSelectionStatus",
    "clearGeneSelectionBtn", "clearCellSelectionBtn", "restorePreviousGenesBtn",
    "geneListHistoryBtn", "geneListHistoryMenu",
    "geneSearchInput", "geneSearchDropdown", "geneSearchList", "geneSearchListEmpty",
    "geneSetOverlapBtn", "toggleAllGenesBtn",
    "mobileLegend"
  ]

  connect() {
    this.dpr = window.devicePixelRatio || 1
    this.showRowTree = true
    this.showColTree = true
    this.showLabels = true
    this.dragging = false
    this.selecting = false
    this.selectionRect = null
    this.interactionMode = "pan"
    this.selectedGenes = new Set()
    this.selectedCells = new Set()
    this.selectedOrigRows = new Set()
    this.selectedOrigCols = new Set()
    // Ordered list of genes added via search or rectangle selection.
    // checked=true genes are highlighted on the heatmap and used for gene-set creation.
    this.geneListItems = []
    this.geneListHistory = []
    this._geneListHistoryBatchDepth = 0
    this._geneListHistoryBefore = null
    this._skipGeneListHistoryRecord = false
    this.geneRowIndexBySymbol = new Map()
    this.geneSearchMatches = []
    this.geneSearchActiveIndex = -1
    this.geneSearchBlurTimer = null
    this.trackModalGeneSetFilterTimer = null
    this.trackModalGeneSetSearchMatches = []
    this.trackModalGeneSetSearchActiveIndex = -1
    this.trackModalGeneSetSearchRequestId = 0
    this.trackModalGeneSetSearchSelectedLabel = ""
    this.pendingTrackGeneSetItemId = null
    this.pendingTrackGeneSetItemName = null
    this.savedCellSets = []
    this.savedCellSetCellsCache = new Map()
    this._cellToOrigColMap = null
    this.loadedMetadataVectors = {}
    this.selectionDataManager = new DataManager(this)
    this.recentlyCreatedSavedCellSetId = null
    this.editingSavedCellSetId = null
    this.pendingSavedCellSetName = null
    this.pendingSavedCellSetFocusId = null
    this.savedCellSetsFilterQuery = ""
    this.savedCellSetsFilterType = "all"
    this.savedCellSetsSortBy = "created_at"
    this.savedCellSetsSortOrder = "desc"
    this.selectionStatesSubscription = null
    this.selectionStatesRefreshTimer = null
    this.selectionStatusPollingTimer = null
    this.embeddingMetadataId = null
    this.colTracks = []
    this.rowTracks = []
    this.loomFile = null
    this.metadataCatalog = { column_metadata: [], row_metadata: [] }
    this.legendMaxCategories = 12
    this.legendBounds = null
    this.trackLegendBounds = []
    this.isHoveringLegend = false
    this.hoveringTrackLegendKey = null
    this.geneSetCollectionsController = new GeneSetCollectionsController(this, {
      idPrefix: "heatmap",
      root: this.element.querySelector("#heatmap-cells-panel") || this.element,
      enableModuleScoreColoring: false,
      createCollectionType: "from_heatmap"
    })
    this.wrapGeneSetCollectionsCheckpointHooks()
    this.geneSetOverlapPopup = new GeneSetOverlapPopup({
      getProjectIdentifier: () => this.getProjectIdentifier(),
      getGenes: () => this.geneListItems
        .filter((item) => item.checked)
        .map((item) => ({ symbol: item.symbol })),
      getBackgroundGenes: () => (this.meta?.row_labels || []).map((symbol) => ({ symbol })),
      getLoomFile: () => this.loomFile || "",
      backgroundContextLabel: "Genes in this heatmap",
      getCsrfToken: () => this.csrfToken()
    })
    // Shared gene-set click path expects geneManager.replaceGenesFromGeneSet (same as visualization).
    this.geneManager = {
      replaceGenesFromGeneSet: (geneEntries) => this.replaceGenesFromGeneSet(geneEntries)
    }
    this.currentSelectionTab = "cells"
    this.editingGradientTarget = { type: "expression" }
    this.expressionCustomColorRange = null
    this.checkpointHistory = []
    this.currentAutoCheckpoint = null
    this.lastLoadedCheckpointId = null
    this.checkpointCommentsFocusId = null
    this.currentCheckpointLoadInProgress = false
    this.currentCheckpointReadyForOverwrite = false

    // Shared gradient-editor host state (same modal as visualization).
    this.currentMetadataId = "heatmap_expression"
    this.currentMetadataVector = null
    this.metadataGradients = new Map()
    this.gradientControlPoints = null
    this.customGradientControlPoints = null
    this.gradientScale = "normal"
    this.gradientMinValue = undefined
    this.gradientMaxValue = undefined
    this.selectedControlPointIndex = undefined
    this.customColorRange = null
    this.nanColor = DEFAULT_NAN_COLOR_INT
    this.histogramScale = "normal"
    this.histogramIgnoreZeros = true
    this.gradientManager = new GradientManager(this)
    this.colorManager = new ColorManager(this)
    this.dataManager = {
      safeMin: (values) => this.safeMin(values),
      safeMax: (values) => this.safeMax(values),
      getIncrementalFilteredIndices: () => null
    }
    this.rendererManager = {
      renderModalGradientPreview: () => this.gradientManager.renderModalGradientPreview(),
      renderModalControlPointMarkers: () => this.gradientManager.renderModalControlPointMarkers(),
      renderControlPointsList: () => this.gradientManager.renderControlPointsList()
    }

    this.layout = {
      colTreeH: 90,
      rowTreeW: 120,
      trackW: 16,
      trackH: 16,
      trackGap: 3,
      trackRefW: 18,
      trackRefH: 14,
      rowLabelW: 50,
      colLabelH: 90,
      legendW: 220,
      legendWMin: 140,
      legendWMax: 360,
      rightMargin: 8,
      rightMarginMin: 0,
      rightMarginMax: 200,
      pad: 8
    }
    this.legendWidthPx = this.layout.legendW
    this.rightMarginPx = this.layout.rightMargin
    this.rightMargin = this.layout.rightMargin
    this.labelW = 0
    this.legendLeft = 0
    this.trackSizePx = { thin: 10, normal: 16, thick: 24 }
    this.pendingTrackAxis = null

    this.boundResize = this.handleResize.bind(this)
    this.boundPersistCurrent = () => this.persistCurrentCheckpointBeforeTeardown("beforeunload")
    this.boundPersistCurrentTurboCache = () => this.persistCurrentCheckpointBeforeTeardown("turbo:before-cache")
    this.boundPersistCurrentTurboVisit = () => this.persistCurrentCheckpointBeforeTeardown("turbo:before-visit")
    window.addEventListener("resize", this.boundResize)
    window.addEventListener("beforeunload", this.boundPersistCurrent)
    document.addEventListener("turbo:before-cache", this.boundPersistCurrentTurboCache)
    document.addEventListener("turbo:before-visit", this.boundPersistCurrentTurboVisit)

    this.syncToggleButtons()
    this.syncLegendWidthControls()
    this.syncRightMarginControls()
    this.initializePanelLayout()
    this.initializeMobileHeatmapLayout()
    this.boundGeneListHistoryOutsideClick = (event) => {
      if (!this.hasGeneListHistoryMenuTarget) return
      if (this.geneListHistoryMenuTarget.style.display !== "block") return
      const target = event?.target
      if (this.geneListHistoryMenuTarget.contains(target)) return
      if (this.hasGeneListHistoryBtnTarget && this.geneListHistoryBtnTarget.contains(target)) return
      this.closeGeneListHistoryMenu()
    }
    document.addEventListener("click", this.boundGeneListHistoryOutsideClick)
    this.loadData()
  }

  disconnect() {
    this.persistCurrentCheckpointBeforeTeardown("disconnect")
    this.unbindEvents()
    this.teardownMobileHeatmapLayout()
    this.teardownPanelLayout()
    this.teardownSavedCellSetLiveUpdates()
    this.teardownSavedCellSetsFilterMenus()
    if (this.boundGeneListHistoryOutsideClick) {
      document.removeEventListener("click", this.boundGeneListHistoryOutsideClick)
      this.boundGeneListHistoryOutsideClick = null
    }
    if (this.geneSearchBlurTimer) {
      clearTimeout(this.geneSearchBlurTimer)
      this.geneSearchBlurTimer = null
    }
    if (this.trackModalGeneSetFilterTimer) {
      clearTimeout(this.trackModalGeneSetFilterTimer)
      this.trackModalGeneSetFilterTimer = null
    }
    if (this.geneSetOverlapPopup) {
      this.geneSetOverlapPopup.close()
      this.geneSetOverlapPopup = null
    }
    this.geneSetCollectionsController = null
    window.removeEventListener("resize", this.boundResize)
    window.removeEventListener("beforeunload", this.boundPersistCurrent)
    document.removeEventListener("turbo:before-cache", this.boundPersistCurrentTurboCache)
    document.removeEventListener("turbo:before-visit", this.boundPersistCurrentTurboVisit)
    if (this._settingsOutsideCloseBound) {
      document.removeEventListener("mousedown", this._settingsOutsideCloseBound)
      this._settingsOutsideCloseBound = null
    }
    if (this.renderer) {
      this.renderer.destroy()
      this.renderer = null
    }
  }

  getProjectIdentifier() {
    return this.projectKeyValue || null
  }

  getCurrentLoomFileForRequest() {
    return this.loomFile || ""
  }

  setStatus(message, { loading = null } = {}) {
    if (!this.hasStatusTarget) return
    const text = String(message || "").trim()
    if (!text) {
      this.statusTarget.style.display = "none"
      return
    }
    this.statusTarget.style.display = "flex"
    if (this.hasStatusMessageTarget) this.statusMessageTarget.textContent = text
    const showSpinner = loading === true || (loading === null && /^loading\b/i.test(text))
    if (this.hasStatusSpinnerTarget) {
      this.statusSpinnerTarget.style.display = showSpinner ? "block" : "none"
    }
  }

  async loadData() {
    this.setStatus("Loading heatmap...", { loading: true })
    try {
      const metaRes = await fetch(this.dataUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!metaRes.ok) {
        const body = await metaRes.json().catch(() => ({}))
        this.setStatus(body.error || "Heatmap results are not available yet.", { loading: false })
        return
      }
      this.meta = await metaRes.json()
      this._cellToOrigColMap = null
      this.savedCellSetCellsCache = new Map()

      if ((this.meta.warnings || []).length) {
        console.warn("[heatmap] warnings:", this.meta.warnings)
      }

      const matrixUrl = this.meta.matrix_url
      if (!matrixUrl) {
        this.setStatus("Heatmap matrix is missing.", { loading: false })
        return
      }
      const matRes = await fetch(matrixUrl, { credentials: "same-origin" })
      if (!matRes.ok) {
        this.setStatus("Failed to load heatmap matrix.", { loading: false })
        return
      }
      const buf = await matRes.arrayBuffer()
      this.baseMatrix = new Float32Array(buf)

      this.nOrigRows = this.meta.n_rows
      this.nOrigCols = this.meta.n_cols
      this.vmin = this.meta.value_min
      this.vmax = this.meta.value_max
      this.diverging = this.meta.diverging !== false

      if (this.baseMatrix.length !== this.nOrigRows * this.nOrigCols) {
        this.setStatus("Heatmap matrix size does not match metadata.", { loading: false })
        return
      }

      this.rowTree = this.prepareTree(this.meta.row_tree, this.nOrigRows)
      this.colTree = this.prepareTree(this.meta.col_tree, this.nOrigCols)
      this.loomFile = this.meta.loom_file || null
      this.embeddingMetadataId = this.meta.embedding_metadata_id
        ? Number(this.meta.embedding_metadata_id)
        : null
      this.rebuildGeneRowIndex()

      this.setupExpressionGradient()
      this.setStatus("")
      this.setupRenderer()
      this.rebuildDisplay()
      this.resetView(false)
      this.bindEvents()
      await this.loadMetadataCatalog()
      this.handleResize()
      this.syncInteractionModeButtons()
      this.updateSelectionPanels()
      this.setupSavedCellSetLiveUpdates()
      await this.refreshSavedCellSets()
      await this.fetchCheckpointHistory()
      const loadedFromUrl = await this.loadCheckpointFromUrlIfPresent()
      if (!loadedFromUrl) {
        await this.loadCurrentCheckpointOnEntry()
      }
      this.currentCheckpointReadyForOverwrite = true
    } catch (e) {
      console.error("[heatmap] load failed", e)
      this.setStatus("Failed to load heatmap: " + e.message, { loading: false })
      this.currentCheckpointReadyForOverwrite = true
    }
  }

  // Normalize a linkage tree into nodes with min/max leaf indices and a stable id.
  // Supports the flat linkage format ({ n_leaves, merges }) and the legacy
  // nested format ({ leaf, children, height }).
  prepareTree(tree, nLeaves) {
    if (!tree) return null
    if (Array.isArray(tree.merges)) return this.prepareFlatTree(tree)
    return this.prepareNestedTree(tree, nLeaves)
  }

  // Flat linkage: leaves 0..N-1 (display order), internal N..2N-2 (merge order).
  prepareFlatTree(flat) {
    const n = flat.n_leaves
    const nodes = new Array(n + flat.merges.length)
    for (let i = 0; i < n; i++) {
      nodes[i] = { id: i, leaf: true, index: i, minLeaf: i, maxLeaf: i, height: 0 }
    }
    let maxHeight = 0
    flat.merges.forEach((m, i) => {
      const id = n + i
      const left = nodes[m[0]]
      const right = nodes[m[1]]
      const height = m[2]
      if (height > maxHeight) maxHeight = height
      nodes[id] = {
        id,
        leaf: false,
        height,
        children: [left, right],
        minLeaf: Math.min(left.minLeaf, right.minLeaf),
        maxLeaf: Math.max(left.maxLeaf, right.maxLeaf)
      }
    })
    return { root: nodes[nodes.length - 1], maxHeight: maxHeight || 1, nLeaves: n }
  }

  prepareNestedTree(root, nLeaves) {
    let maxHeight = 0
    let counter = 0
    const walk = (node) => {
      node.id = counter++
      if (node.leaf || !node.children || node.children.length === 0) {
        node.leaf = true
        node.minLeaf = node.index
        node.maxLeaf = node.index
        node.height = 0
        return node
      }
      const kids = node.children.map(walk)
      node.minLeaf = Math.min(...kids.map((k) => k.minLeaf))
      node.maxLeaf = Math.max(...kids.map((k) => k.maxLeaf))
      node.height = node.height || 0
      if (node.height > maxHeight) maxHeight = node.height
      return node
    }
    walk(root)
    return { root, maxHeight: maxHeight || 1, nLeaves }
  }

  setupRenderer() {
    this.renderer = new ReglHeatmap(this.webglTarget)
    this.applyActiveColormap()
  }

  setupExpressionGradient() {
    this.currentMetadataVector = {
      data_type: "NUMERIC",
      values: this.baseMatrix,
      compression_info: { min_val: this.vmin, max_val: this.vmax }
    }
    this.gradientMinValue = this.vmin
    this.gradientMaxValue = this.vmax
    this.customColorRange = null
    this.gradientScale = "normal"
    this.customGradientControlPoints = null
    this.colorManager.initializeDefaultGradient()
    if (!this.gradientControlPoints || !this.gradientControlPoints.length) {
      this.gradientControlPoints = this.defaultHeatmapControlPoints()
    }
    this.gradientManager.saveGradientForMetadata(this.currentMetadataId)
    this.editingGradientTarget = { type: "expression" }
    this.expressionCustomColorRange = null
  }

  defaultHeatmapControlPoints() {
    if (this.diverging) {
      const zeroPos = (0 - this.vmin) / ((this.vmax - this.vmin) || 1)
      const clampedZero = Math.min(1, Math.max(0, zeroPos))
      return [
        { position: 0, color: 0x3b4dbf },
        { position: clampedZero, color: 0xf7f7f7 },
        { position: 1, color: 0xb5171a }
      ]
    }
    return [
      { position: 0, color: 0x450a54 },
      { position: 0.5, color: 0x21918c },
      { position: 1, color: 0xfce728 }
    ]
  }

  activeControlPoints() {
    return this.customGradientControlPoints || this.gradientControlPoints || this.defaultHeatmapControlPoints()
  }

  expressionGradientState() {
    const stored = this.metadataGradients.get("heatmap_expression")
    if (stored) return stored
    return {
      gradientControlPoints: this.defaultHeatmapControlPoints(),
      customGradientControlPoints: null,
      gradientScale: "normal",
      nanColor: nanColorToHex(DEFAULT_NAN_COLOR_INT)
    }
  }

  applyActiveColormap() {
    if (!this.renderer) return
    const stored = this.expressionGradientState()
    const prevCustom = this.customGradientControlPoints
    const prevDefault = this.gradientControlPoints
    const prevScale = this.gradientScale
    const prevNan = this.nanColor
    this.customGradientControlPoints = stored.customGradientControlPoints
      ? JSON.parse(JSON.stringify(stored.customGradientControlPoints))
      : null
    this.gradientControlPoints = stored.gradientControlPoints
      ? JSON.parse(JSON.stringify(stored.gradientControlPoints))
      : this.defaultHeatmapControlPoints()
    this.gradientScale = stored.gradientScale === "log" ? "log" : "normal"
    this.nanColor = parseNanColor(stored.nanColor)
    const points = this.activeControlPoints()
    this.renderer.setColormapFromControlPoints(points, (t) => this.gradientManager.getColorFromGradient(t))
    this.renderer.setNanColor(this.nanColor)
    this.customGradientControlPoints = prevCustom
    this.gradientControlPoints = prevDefault
    this.gradientScale = prevScale
    this.nanColor = prevNan
  }

  normalizeExpressionValue(value, vmin, vmax) {
    const stored = this.expressionGradientState()
    const prevScale = this.gradientScale
    this.gradientScale = stored.gradientScale === "log" ? "log" : "normal"
    const position = this.valueToGradientPosition(value, vmin, vmax)
    this.gradientScale = prevScale
    return position
  }

  async loadMetadataCatalog() {
    if (!this.projectKeyValue || !this.runIdValue) return
    try {
      const url = `/projects/${encodeURIComponent(this.projectKeyValue)}/heatmap_metadata_catalog?run_id=${encodeURIComponent(this.runIdValue)}`
      const res = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      if (!res.ok) return
      this.metadataCatalog = await res.json()
      if (this.metadataCatalog.loom_file) {
        this.loomFile = this.metadataCatalog.loom_file
      }
      this.populateTrackSelects()
    } catch (e) {
      console.warn("[heatmap] metadata catalog failed", e)
    }
  }

  populateTrackSelects() {
    // Track selects now live in the add-track modal; refresh if it is open.
    if (this.pendingTrackAxis) this.fillTrackModalSelect(this.pendingTrackAxis)
  }

  fillTrackModalSelect(axis) {
    if (!this.hasTrackModalSelectTarget) return
    const options = axis === "column"
      ? (this.metadataCatalog.column_metadata || [])
      : (this.metadataCatalog.row_metadata || [])
    const activeTracks = axis === "column" ? this.colTracks : this.rowTracks
    const activeIds = new Set(activeTracks.map((t) => String(t.id)))
    const selectEl = this.trackModalSelectTarget
    selectEl.innerHTML = ""
    const placeholder = document.createElement("option")
    placeholder.value = ""
    placeholder.textContent = options.length ? "Select metadata..." : "No metadata available"
    selectEl.appendChild(placeholder)
    options.forEach((opt) => {
      if (activeIds.has(String(opt.id))) return
      const option = document.createElement("option")
      option.value = String(opt.id)
      option.textContent = opt.name
      option.dataset.dataType = opt.data_type || ""
      option.dataset.nberCats = String(opt.nber_cats != null ? opt.nber_cats : "")
      selectEl.appendChild(option)
    })
    this.trackModalMetadataChanged()
  }

  openAddColTrackModal() {
    this.openTrackModal("column")
  }

  openAddRowTrackModal() {
    this.openTrackModal("row")
  }

  openImportMetadata(event) {
    const button = event.currentTarget
    const typeId = String(
      (event.params && event.params.metadataType != null)
        ? event.params.metadataType
        : (button && button.getAttribute("data-heatmap-metadata-type-param")) || "1"
    )
    if (typeof window.openAddMetadataModal === "function") {
      window.openAddMetadataModal(typeId)
      return
    }
    const modal = document.getElementById("add-metadata-modal")
    if (modal) modal.classList.remove("hidden")
  }

  openTrackModal(axis) {
    this.pendingTrackAxis = axis
    this.pendingTrackGeneSetItemId = null
    this.pendingTrackGeneSetItemName = null
    this.trackModalGeneSetSearchSelectedLabel = ""
    this.trackModalGeneSetSearchMatches = []
    this.trackModalGeneSetSearchActiveIndex = -1
    if (this.hasTrackModalTitleTarget) {
      this.trackModalTitleTarget.textContent = axis === "column"
        ? "Add cell metadata track"
        : "Add gene metadata track"
    }
    if (this.hasTrackModalSizeTarget) this.trackModalSizeTarget.value = "normal"
    if (this.hasTrackModalShowLegendTarget) this.trackModalShowLegendTarget.checked = false
    if (this.hasTrackModalSourceTarget) this.trackModalSourceTarget.value = "metadata"
    if (this.hasTrackModalGeneSetSearchTarget) this.trackModalGeneSetSearchTarget.value = ""
    this.hideTrackModalGeneSetSearchResults()
    this.syncTrackModalSourceVisibility()
    this.fillTrackModalSelect(axis)
    if (this.hasTrackModalTarget) {
      this.trackModalTarget.style.display = "flex"
    }
  }

  closeTrackModal() {
    this.pendingTrackAxis = null
    this.pendingTrackGeneSetItemId = null
    this.pendingTrackGeneSetItemName = null
    this.trackModalGeneSetSearchSelectedLabel = ""
    this.trackModalGeneSetSearchMatches = []
    this.trackModalGeneSetSearchActiveIndex = -1
    if (this.trackModalGeneSetFilterTimer) {
      clearTimeout(this.trackModalGeneSetFilterTimer)
      this.trackModalGeneSetFilterTimer = null
    }
    this.hideTrackModalGeneSetSearchResults()
    if (this.hasTrackModalTarget) this.trackModalTarget.style.display = "none"
  }

  trackModalBackdropClick(event) {
    if (event.target === this.trackModalTarget) this.closeTrackModal()
  }

  stopModalPropagation(event) {
    event.stopPropagation()
  }

  currentTrackModalSource() {
    if (this.pendingTrackAxis !== "row") return "metadata"
    if (!this.hasTrackModalSourceTarget) return "metadata"
    return this.trackModalSourceTarget.value === "gene_set_membership"
      ? "gene_set_membership"
      : "metadata"
  }

  syncTrackModalSourceVisibility() {
    const isRow = this.pendingTrackAxis === "row"
    const source = this.currentTrackModalSource()
    if (this.hasTrackModalSourceWrapTarget) {
      this.trackModalSourceWrapTarget.style.display = isRow ? "block" : "none"
    }
    if (this.hasTrackModalMetadataWrapTarget) {
      this.trackModalMetadataWrapTarget.style.display = (!isRow || source === "metadata") ? "block" : "none"
    }
    if (this.hasTrackModalGeneSetWrapTarget) {
      this.trackModalGeneSetWrapTarget.style.display = (isRow && source === "gene_set_membership") ? "block" : "none"
    }
    this.trackModalMetadataChanged()
  }

  trackModalSourceChanged() {
    this.syncTrackModalSourceVisibility()
    if (this.currentTrackModalSource() === "gene_set_membership") {
      this.pendingTrackGeneSetItemId = null
      this.pendingTrackGeneSetItemName = null
      this.trackModalGeneSetSearchSelectedLabel = ""
      if (this.hasTrackModalGeneSetSearchTarget) this.trackModalGeneSetSearchTarget.value = ""
      this.hideTrackModalGeneSetSearchResults()
      this.trackModalMetadataChanged()
    }
  }

  trackModalGeneSetSearchInputChanged() {
    if (!this.hasTrackModalGeneSetSearchTarget) return
    const query = String(this.trackModalGeneSetSearchTarget.value || "")
    if (this.trackModalGeneSetSearchSelectedLabel && query !== this.trackModalGeneSetSearchSelectedLabel) {
      this.pendingTrackGeneSetItemId = null
      this.pendingTrackGeneSetItemName = null
      this.trackModalGeneSetSearchSelectedLabel = ""
      this.trackModalMetadataChanged()
    }
    if (this.trackModalGeneSetFilterTimer) clearTimeout(this.trackModalGeneSetFilterTimer)
    this.trackModalGeneSetFilterTimer = setTimeout(() => {
      this.searchTrackModalGeneSets(query.trim())
    }, 250)
  }

  trackModalGeneSetSearchKeydown(event) {
    const key = event?.key
    if (key === "Escape") {
      this.hideTrackModalGeneSetSearchResults()
      return
    }
    if (key === "ArrowDown") {
      if (!this.trackModalGeneSetSearchMatches.length) return
      event.preventDefault()
      this.trackModalGeneSetSearchActiveIndex = Math.min(
        this.trackModalGeneSetSearchMatches.length - 1,
        this.trackModalGeneSetSearchActiveIndex + 1
      )
      this.renderTrackModalGeneSetSearchResults()
      return
    }
    if (key === "ArrowUp") {
      if (!this.trackModalGeneSetSearchMatches.length) return
      event.preventDefault()
      this.trackModalGeneSetSearchActiveIndex = Math.max(0, this.trackModalGeneSetSearchActiveIndex - 1)
      this.renderTrackModalGeneSetSearchResults()
      return
    }
    if (key === "Enter") {
      if (this.trackModalGeneSetSearchMatches.length && this.trackModalGeneSetSearchActiveIndex >= 0) {
        event.preventDefault()
        this.selectTrackModalGeneSetMatch(this.trackModalGeneSetSearchMatches[this.trackModalGeneSetSearchActiveIndex])
      }
    }
  }

  trackModalGeneSetSearchBlur() {
    setTimeout(() => this.hideTrackModalGeneSetSearchResults(), 150)
  }

  async searchTrackModalGeneSets(query) {
    if (!this.hasTrackModalGeneSetSearchResultsTarget || !this.projectKeyValue) return
    const collections = Array.isArray(this.metadataCatalog?.gene_set_collections)
      ? this.metadataCatalog.gene_set_collections
      : []
    if (!collections.length) {
      this.trackModalGeneSetSearchMatches = []
      this.trackModalGeneSetSearchActiveIndex = -1
      this.renderTrackModalGeneSetSearchMessage("No gene set collections available")
      return
    }
    if (!String(query || "").trim()) {
      this.trackModalGeneSetSearchMatches = []
      this.trackModalGeneSetSearchActiveIndex = -1
      this.renderTrackModalGeneSetSearchMessage("Type to search gene sets...")
      return
    }

    const loomFile = String(this.loomFile || "")
    if (!loomFile) {
      this.trackModalGeneSetSearchMatches = []
      this.trackModalGeneSetSearchActiveIndex = -1
      this.renderTrackModalGeneSetSearchMessage("Heatmap loom file is not available yet")
      return
    }

    const requestId = ++this.trackModalGeneSetSearchRequestId
    const activeIds = new Set(
      this.rowTracks
        .filter((t) => t.source === "gene_set_membership")
        .map((t) => String(t.geneSetItemId || ""))
    )

    try {
      const batches = await Promise.all(collections.map(async (collection) => {
        const collectionId = String(collection.id || "").trim()
        if (!collectionId) return []
        const params = new URLSearchParams({
          collection_id: collectionId,
          query: String(query || "").trim(),
          loom_file: loomFile
        })
        const response = await fetch(
          `/projects/${encodeURIComponent(this.projectKeyValue)}/gene_set_collection_items?${params.toString()}`,
          { headers: { Accept: "application/json" }, credentials: "same-origin" }
        )
        const payload = await response.json().catch(() => ({}))
        if (!response.ok || payload.status !== "ok") return []
        const collectionLabel = collection.label || collectionId
        return (Array.isArray(payload.items) ? payload.items : []).map((item) => ({
          ...item,
          collection_id: collectionId,
          collection_label: collectionLabel
        }))
      }))

      if (requestId !== this.trackModalGeneSetSearchRequestId) return

      const merged = []
      const seen = new Set()
      for (const item of batches.flat()) {
        const itemId = String(item.id || "").trim()
        if (!itemId || activeIds.has(itemId) || seen.has(itemId)) continue
        seen.add(itemId)
        merged.push(item)
      }
      merged.sort((a, b) => {
        const aName = String(a.name || a.identifier || a.id || "").toLowerCase()
        const bName = String(b.name || b.identifier || b.id || "").toLowerCase()
        return aName.localeCompare(bName)
      })
      this.trackModalGeneSetSearchMatches = merged.slice(0, 50)
      this.trackModalGeneSetSearchActiveIndex = this.trackModalGeneSetSearchMatches.length ? 0 : -1
      this.renderTrackModalGeneSetSearchResults()
    } catch (error) {
      if (requestId !== this.trackModalGeneSetSearchRequestId) return
      console.warn("[heatmap] gene set search failed", error)
      this.trackModalGeneSetSearchMatches = []
      this.trackModalGeneSetSearchActiveIndex = -1
      this.renderTrackModalGeneSetSearchMessage(error.message || "Failed to search gene sets")
    }
  }

  renderTrackModalGeneSetSearchMessage(message) {
    if (!this.hasTrackModalGeneSetSearchResultsTarget) return
    const resultsEl = this.trackModalGeneSetSearchResultsTarget
    resultsEl.innerHTML = ""
    const row = document.createElement("div")
    row.style.cssText = "padding:10px 12px;font-size:12px;color:#6b7280;"
    row.textContent = message
    resultsEl.appendChild(row)
    resultsEl.style.display = "block"
  }

  renderTrackModalGeneSetSearchResults() {
    if (!this.hasTrackModalGeneSetSearchResultsTarget) return
    const resultsEl = this.trackModalGeneSetSearchResultsTarget
    resultsEl.innerHTML = ""
    if (!this.trackModalGeneSetSearchMatches.length) {
      this.renderTrackModalGeneSetSearchMessage("No matching gene sets")
      return
    }

    this.trackModalGeneSetSearchMatches.forEach((item, index) => {
      const itemId = String(item.id || "").trim()
      const name = String(item.name || item.identifier || itemId).trim() || itemId
      const identifier = String(item.identifier || "").trim()
      const collectionLabel = String(item.collection_label || "").trim()
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.action = "mousedown->heatmap#onTrackModalGeneSetSearchOptionSelect"
      button.dataset.itemId = itemId
      button.dataset.itemIndex = String(index)
      const active = index === this.trackModalGeneSetSearchActiveIndex
      button.style.cssText = `display:block;width:100%;text-align:left;padding:8px 12px;border:none;border-bottom:1px solid #f3f4f6;cursor:pointer;background:${active ? "#eff6ff" : "#fff"};`
      button.onmouseover = function () { this.style.backgroundColor = "#f3f4f6" }
      button.onmouseout = function () { this.style.backgroundColor = active ? "#eff6ff" : "#fff" }
      const countParts = []
      if (item.gene_count != null) countParts.push(`${item.gene_count} genes`)
      if (item.in_dataset_count != null) countParts.push(`${item.in_dataset_count} in dataset`)
      const titleBits = []
      if (identifier && identifier !== name) titleBits.push(this.escapeHtml(identifier))
      titleBits.push(this.escapeHtml(name))
      button.innerHTML = `
        <div style="font-size:12px;font-weight:600;color:#111827;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">${titleBits.join(" ")}</div>
        <div style="margin-top:2px;font-size:11px;color:#6b7280;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">
          ${this.escapeHtml(collectionLabel)}${countParts.length ? ` · ${this.escapeHtml(countParts.join(", "))}` : ""}
        </div>
      `
      resultsEl.appendChild(button)
    })
    resultsEl.style.display = "block"
  }

  hideTrackModalGeneSetSearchResults() {
    if (!this.hasTrackModalGeneSetSearchResultsTarget) return
    this.trackModalGeneSetSearchResultsTarget.style.display = "none"
    this.trackModalGeneSetSearchResultsTarget.innerHTML = ""
  }

  onTrackModalGeneSetSearchOptionSelect(event) {
    if (event) event.preventDefault()
    const index = Number(event?.currentTarget?.dataset?.itemIndex)
    const item = Number.isInteger(index) ? this.trackModalGeneSetSearchMatches[index] : null
    if (!item) return
    this.selectTrackModalGeneSetMatch(item)
  }

  selectTrackModalGeneSetMatch(item) {
    if (!item) return
    const itemId = String(item.id || "").trim()
    if (!itemId) return
    const name = String(item.name || item.identifier || itemId).trim() || itemId
    const collectionLabel = String(item.collection_label || "").trim()
    const label = collectionLabel ? `${name} (${collectionLabel})` : name
    this.pendingTrackGeneSetItemId = itemId
    this.pendingTrackGeneSetItemName = name
    this.trackModalGeneSetSearchSelectedLabel = label
    if (this.hasTrackModalGeneSetSearchTarget) this.trackModalGeneSetSearchTarget.value = label
    this.hideTrackModalGeneSetSearchResults()
    this.trackModalMetadataChanged()
  }

  trackModalMetadataChanged() {
    if (this.currentTrackModalSource() === "gene_set_membership") {
      if (this.hasTrackModalLegendWrapTarget) this.trackModalLegendWrapTarget.style.display = "flex"
      if (this.hasTrackModalShowLegendTarget) this.trackModalShowLegendTarget.checked = true
      if (this.hasTrackModalHintTarget) {
        if (this.pendingTrackGeneSetItemId) {
          this.trackModalHintTarget.textContent =
            "Adds a boolean track colored by whether each gene is present or absent in the selected gene set."
        } else {
          this.trackModalHintTarget.textContent = "Search and choose a gene set."
        }
      }
      return
    }
    if (!this.hasTrackModalSelectTarget) return
    const selected = this.trackModalSelectTarget.selectedOptions[0]
    const dataType = (selected?.dataset?.dataType || "").toUpperCase()
    const isCategorical = dataType !== "NUMERIC" && dataType !== "CONTINUOUS"
    const nberCats = Number(selected?.dataset?.nberCats)
    const legendFits = Number.isFinite(nberCats) && nberCats > 0 && nberCats <= this.legendMaxCategories
    if (this.hasTrackModalLegendWrapTarget) {
      this.trackModalLegendWrapTarget.style.display = isCategorical ? "flex" : "none"
    }
    if (this.hasTrackModalShowLegendTarget) {
      this.trackModalShowLegendTarget.checked = isCategorical && legendFits
    }
    if (this.hasTrackModalHintTarget) {
      if (!selected || !selected.value) {
        this.trackModalHintTarget.textContent = "Choose a metadata annotation to display beside the heatmap."
      } else if (isCategorical) {
        this.trackModalHintTarget.textContent = "Categorical tracks are colored by category."
      } else {
        this.trackModalHintTarget.textContent = "Numerical tracks use a light-to-dark blue scale from low to high values."
      }
    }
  }

  async confirmAddTrack() {
    const axis = this.pendingTrackAxis
    if (!axis) return
    const sizeKey = this.trackModalSizeTarget?.value || "normal"
    const thickness = this.trackSizePx[sizeKey] || this.layout.trackH

    if (axis === "row" && this.currentTrackModalSource() === "gene_set_membership") {
      const itemId = this.pendingTrackGeneSetItemId
      if (!itemId) return
      const itemName = this.pendingTrackGeneSetItemName || itemId
      const showLegend = !!(this.trackModalShowLegendTarget?.checked)
      this.closeTrackModal()
      await this.addGeneSetMembershipTrack(itemId, {
        thickness,
        showLegend,
        name: itemName
      })
      return
    }

    const id = this.trackModalSelectTarget?.value
    if (!id) return
    const selected = this.trackModalSelectTarget.selectedOptions[0]
    const dataType = (selected?.dataset?.dataType || "").toUpperCase()
    const isCategorical = dataType !== "NUMERIC" && dataType !== "CONTINUOUS"
    const showLegend = isCategorical && !!(this.trackModalShowLegendTarget?.checked)
    this.closeTrackModal()
    await this.addTrack(id, axis, {
      thickness,
      showLegend
    })
  }

  async addColTrack() {
    this.openAddColTrackModal()
  }

  async addRowTrack() {
    this.openAddRowTrackModal()
  }

  geneSetMembershipTrackId(itemId) {
    return `gene_set_membership:${String(itemId)}`
  }

  async fetchGeneSetItemGenesForTrack(itemId) {
    const params = new URLSearchParams({
      item_id: String(itemId),
      loom_file: String(this.loomFile || "")
    })
    const response = await fetch(
      `/projects/${encodeURIComponent(this.projectKeyValue)}/gene_set_item_genes?${params.toString()}`,
      { headers: { Accept: "application/json" }, credentials: "same-origin" }
    )
    const payload = await response.json().catch(() => ({}))
    if (!response.ok || payload.status !== "ok") {
      throw new Error(payload.message || "Failed to load genes from gene set")
    }
    return payload
  }

  buildGeneSetMembershipValues(genes) {
    const present = new Set()
    for (const gene of Array.isArray(genes) ? genes : []) {
      const symbol = gene?.symbol != null ? String(gene.symbol).trim() : ""
      if (symbol) present.add(symbol.toLowerCase())
      const ensembl = gene?.ensembl_id != null ? String(gene.ensembl_id).trim() : ""
      if (ensembl) present.add(ensembl.toLowerCase())
    }
    const rowLabels = this.meta?.row_labels || []
    return rowLabels.map((label) => {
      const key = label == null ? "" : String(label).trim().toLowerCase()
      if (!key) return "absent"
      return present.has(key) ? "present" : "absent"
    })
  }

  async addGeneSetMembershipTrack(itemId, options = {}) {
    const cleanItemId = String(itemId || "").trim()
    if (!cleanItemId) return
    const trackId = this.geneSetMembershipTrackId(cleanItemId)
    if (this.rowTracks.some((t) => String(t.id) === trackId)) return

    const loading = {
      id: trackId,
      name: options.name || "Loading gene set...",
      type: "categorical",
      values: [],
      loading: true,
      thickness: options.thickness || this.layout.trackH,
      source: "gene_set_membership",
      geneSetItemId: cleanItemId
    }
    this.rowTracks.push(loading)
    this.renderTrackLists()
    this.handleResize()

    try {
      const payload = await this.fetchGeneSetItemGenesForTrack(cleanItemId)
      const values = this.buildGeneSetMembershipValues(payload.genes)
      const trackName = options.name || payload.item?.name || payload.name || cleanItemId
      const track = {
        id: trackId,
        name: String(trackName).startsWith("Gene set:") ? trackName : `Gene set: ${trackName}`,
        type: "categorical",
        values,
        categories: ["absent", "present"],
        source: "gene_set_membership",
        geneSetItemId: cleanItemId,
        categoryColors: {
          absent: "#d1d5db",
          present: "#2563eb"
        }
      }
      const prepared = this.prepareTrack(track, {
        thickness: options.thickness || this.layout.trackH,
        showLegend: Object.prototype.hasOwnProperty.call(options, "showLegend")
          ? !!options.showLegend
          : true,
        type: "categorical"
      })
      prepared.source = "gene_set_membership"
      prepared.geneSetItemId = cleanItemId
      prepared.categoryColors = {
        absent: "#d1d5db",
        present: "#2563eb"
      }
      // Keep stable category order and colors for the boolean legend.
      prepared.categories = ["absent", "present"]
      prepared._catIndex = { absent: 0, present: 1 }
      const idx = this.rowTracks.findIndex((t) => String(t.id) === trackId && t.loading)
      if (idx >= 0) this.rowTracks[idx] = prepared
      else this.rowTracks.push(prepared)
    } catch (e) {
      const idx = this.rowTracks.findIndex((t) => String(t.id) === trackId && t.loading)
      if (idx >= 0) this.rowTracks.splice(idx, 1)
      console.error("[heatmap] add gene set membership track failed", e)
      if (options.persist !== false) {
        alert(e.message || "Failed to add gene set membership track")
      }
    }
    this.populateTrackSelects()
    this.renderTrackLists()
    this.handleResize()
    if (options.persist !== false) {
      this.persistCurrentCheckpointOnServer("add-gene-set-membership-track")
    }
  }

  async addTrack(metadataId, axis, options = {}) {
    const list = axis === "column" ? this.colTracks : this.rowTracks
    if (list.some((t) => String(t.id) === String(metadataId))) return

    const loading = {
      id: metadataId,
      name: "Loading...",
      type: "categorical",
      values: [],
      loading: true,
      thickness: options.thickness || this.layout.trackH
    }
    list.push(loading)
    this.renderTrackLists()
    this.handleResize()

    try {
      const track = await this.fetchTrack(metadataId, axis)
      const prepared = this.prepareTrack(track, options)
      const idx = list.findIndex((t) => String(t.id) === String(metadataId) && t.loading)
      if (idx >= 0) list[idx] = prepared
      else list.push(prepared)
    } catch (e) {
      const idx = list.findIndex((t) => String(t.id) === String(metadataId) && t.loading)
      if (idx >= 0) list.splice(idx, 1)
      console.error("[heatmap] add track failed", e)
    }
    this.populateTrackSelects()
    this.renderTrackLists()
    this.handleResize()
    const added = (axis === "column" ? this.colTracks : this.rowTracks)
      .find((t) => !t.loading && String(t.id) === String(metadataId))
    if (added?.type === "numerical") {
      this.metadataGradients.set(this.trackGradientMetadataId(added), {
        gradientControlPoints: JSON.parse(JSON.stringify(added.gradientControlPoints || this.defaultNumericalTrackControlPoints())),
        customGradientControlPoints: added.customGradientControlPoints
          ? JSON.parse(JSON.stringify(added.customGradientControlPoints))
          : null,
        gradientScale: added.gradientScale === "log" ? "log" : "normal",
        nanColor: nanColorToHex(added.nanColor)
      })
    }
    this.persistCurrentCheckpointOnServer("add-track")
  }

  removeColTrack(event) {
    this.removeTrack(event.params.id, "column")
  }

  removeRowTrack(event) {
    this.removeTrack(event.params.id, "row")
  }

  removeTrack(metadataId, axis) {
    const list = axis === "column" ? this.colTracks : this.rowTracks
    const idx = list.findIndex((t) => String(t.id) === String(metadataId))
    if (idx < 0) return
    list.splice(idx, 1)
    this.populateTrackSelects()
    this.renderTrackLists()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("remove-track")
  }

  async fetchTrack(metadataId, axis) {
    const params = new URLSearchParams({
      run_id: this.runIdValue,
      metadata_id: metadataId,
      axis
    })
    if (this.loomFile) params.set("loom_file", this.loomFile)
    const url = `/projects/${encodeURIComponent(this.projectKeyValue)}/heatmap_track?${params.toString()}`
    const res = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
    const body = await res.json().catch(() => ({}))
    if (!res.ok) throw new Error(body.error || "Failed to load track")
    return body
  }

  prepareTrack(track, options = {}) {
    const nativeType = track.type === "numerical" ? "numerical" : "categorical"
    const values = Array.isArray(track.values) ? track.values.slice() : []
    const prepared = {
      id: track.id,
      name: track.name,
      nativeType,
      type: nativeType,
      values,
      _sourceValues: values.slice(),
      min: track.min,
      max: track.max,
      categories: Array.isArray(track.categories) ? track.categories.slice() : [],
      thickness: options.thickness || this.layout.trackH,
      showLegend: false,
      displayMode: options.displayMode === "barplot" ? "barplot" : "color",
      _catIndex: {}
    }
    if (Object.prototype.hasOwnProperty.call(options, "type") &&
        (options.type === "numerical" || options.type === "categorical")) {
      prepared.type = options.type
    }
    this.applyLocalTrackType(prepared, prepared.type)
    const legendFits = prepared.type === "categorical" &&
      Array.isArray(prepared.categories) &&
      prepared.categories.length > 0 &&
      prepared.categories.length <= this.legendMaxCategories
    if (Object.prototype.hasOwnProperty.call(options, "showLegend")) {
      prepared.showLegend = !!options.showLegend
    } else {
      prepared.showLegend = legendFits
    }
    if (prepared.type === "numerical") {
      this.applyGradientOptionsToTrack(prepared, options.gradient)
      this.ensureTrackGradient(prepared)
    }
    return prepared
  }

  trackValuesAreNumeric(track) {
    const values = track?._sourceValues || track?.values
    if (!track || !Array.isArray(values)) return false
    let seen = 0
    for (let i = 0; i < values.length; i++) {
      const v = values[i]
      if (v === null || v === undefined || v === "") continue
      if (typeof v === "number" && Number.isNaN(v)) continue
      if (typeof v === "string" && /^\s*[-+]?nan\s*$/i.test(v)) continue
      const n = Number(v)
      if (!Number.isFinite(n)) return false
      seen++
    }
    return seen > 0
  }

  canUseTrackType(track, type) {
    if (!track) return false
    if (type === "categorical") return true
    if (type === "numerical") {
      return track.nativeType === "numerical" || this.trackValuesAreNumeric(track)
    }
    return false
  }

  applyLocalTrackType(track, type) {
    if (!track || (type !== "categorical" && type !== "numerical")) return
    if (!this.canUseTrackType(track, type)) return
    track.type = type
    const source = Array.isArray(track._sourceValues) ? track._sourceValues : track.values
    if (type === "categorical") {
      track.values = source.slice()
      const cats = []
      const seen = new Set()
      track.values.forEach((v) => {
        if (v === null || v === undefined || v === "") return
        const key = String(v)
        if (seen.has(key)) return
        seen.add(key)
        cats.push(key)
      })
      cats.sort()
      track.categories = cats
      track._catIndex = {}
      cats.forEach((cat, i) => { track._catIndex[cat] = i })
      track.showLegend = track.categories.length > 0 &&
        track.categories.length <= this.legendMaxCategories
      return
    }
    const nums = source.map((v) => {
      if (v === null || v === undefined || v === "") return null
      const n = Number(v)
      return Number.isFinite(n) ? n : null
    })
    track.values = nums
    const finite = nums.filter((v) => v !== null)
    track.min = finite.length ? Math.min(...finite) : 0
    track.max = finite.length ? Math.max(...finite) : 1
    track._catIndex = {}
    this.ensureTrackGradient(track)
  }

  sizeKeyForThickness(thickness) {
    const t = Number(thickness) || this.layout.trackH
    const entries = Object.entries(this.trackSizePx)
    let best = "normal"
    let bestDist = Infinity
    entries.forEach(([key, px]) => {
      const d = Math.abs(px - t)
      if (d < bestDist) {
        bestDist = d
        best = key
      }
    })
    return best
  }

  trackGradientMetadataId(track) {
    return `heatmap_track_${track.id}`
  }

  defaultNumericalTrackControlPoints() {
    return [
      { position: 0, color: 0xffffff },
      { position: 1, color: 0x0000ff }
    ]
  }

  ensureTrackGradient(track) {
    if (!track || track.type !== "numerical") return
    if (!Array.isArray(track.gradientControlPoints) || !track.gradientControlPoints.length) {
      track.gradientControlPoints = this.defaultNumericalTrackControlPoints()
    }
    if (!track.gradientScale) track.gradientScale = "normal"
    if (!Object.prototype.hasOwnProperty.call(track, "customColorRange")) {
      track.customColorRange = null
    }
    if (!Object.prototype.hasOwnProperty.call(track, "customGradientControlPoints")) {
      track.customGradientControlPoints = null
    }
    track.nanColor = parseNanColor(track.nanColor)
  }

  applyGradientOptionsToTrack(track, gradient) {
    if (!gradient || typeof gradient !== "object") return
    if (Array.isArray(gradient.controlPoints) && gradient.controlPoints.length) {
      const points = gradient.controlPoints.map((p) => ({
        position: Number(p.position),
        color: Number(p.color)
      }))
      track.customGradientControlPoints = points
      track.gradientControlPoints = points
    }
    if (Object.prototype.hasOwnProperty.call(gradient, "customColorRange")) {
      track.customColorRange = gradient.customColorRange
        ? { min: Number(gradient.customColorRange.min), max: Number(gradient.customColorRange.max) }
        : null
    }
    if (gradient.gradientScale) {
      track.gradientScale = gradient.gradientScale === "log" ? "log" : "normal"
    }
    if (Object.prototype.hasOwnProperty.call(gradient, "nanColor")) {
      track.nanColor = parseNanColor(gradient.nanColor)
    }
  }

  activeTrackControlPoints(track) {
    this.ensureTrackGradient(track)
    return track.customGradientControlPoints || track.gradientControlPoints || this.defaultNumericalTrackControlPoints()
  }

  findTrackById(trackId, axis = null) {
    const lists = []
    if (!axis || axis === "column") lists.push(["column", this.colTracks])
    if (!axis || axis === "row") lists.push(["row", this.rowTracks])
    for (const [axisName, list] of lists) {
      const track = list.find((t) => !t.loading && String(t.id) === String(trackId))
      if (track) return { track, axis: axisName }
    }
    return null
  }

  colorIntToCss(colorInt) {
    const n = (Number(colorInt) >>> 0) & 0xffffff
    return `#${n.toString(16).padStart(6, "0")}`
  }

  interpolateGradientColor(points, normalizedValue) {
    if (normalizedValue < 0 || normalizedValue > 1 || Number.isNaN(normalizedValue)) {
      return this.getMissingNumericColor()
    }
    if (!Array.isArray(points) || !points.length) return this.getMissingNumericColor()
    const sorted = [...points].sort((a, b) => a.position - b.position)
    for (let i = 0; i < sorted.length; i++) {
      if (Math.abs(sorted[i].position - normalizedValue) < 0.0001) return sorted[i].color
    }
    let left = sorted[0]
    let right = sorted[sorted.length - 1]
    for (let i = 0; i < sorted.length - 1; i++) {
      if (normalizedValue >= sorted[i].position && normalizedValue <= sorted[i + 1].position) {
        left = sorted[i]
        right = sorted[i + 1]
        break
      }
    }
    if (normalizedValue <= left.position) return left.color
    if (normalizedValue >= right.position) return right.color
    const span = right.position - left.position
    const t = span > 0 ? (normalizedValue - left.position) / span : 0
    const lr = (left.color >> 16) & 255
    const lg = (left.color >> 8) & 255
    const lb = left.color & 255
    const rr = (right.color >> 16) & 255
    const rg = (right.color >> 8) & 255
    const rb = right.color & 255
    const r = Math.round(lr + (rr - lr) * t)
    const g = Math.round(lg + (rg - lg) * t)
    const b = Math.round(lb + (rb - lb) * t)
    return (r << 16) | (g << 8) | b
  }

  trackValueRange(track) {
    if (track.customColorRange &&
        Number.isFinite(Number(track.customColorRange.min)) &&
        Number.isFinite(Number(track.customColorRange.max))) {
      return {
        min: Number(track.customColorRange.min),
        max: Number(track.customColorRange.max)
      }
    }
    return { min: Number(track.min), max: Number(track.max) }
  }

  trackNormalizedPosition(track, value) {
    const range = this.trackValueRange(track)
    const minVal = range.min
    const maxVal = range.max
    if (!Number.isFinite(minVal) || !Number.isFinite(maxVal)) return 0.5
    if (track.gradientScale === "log" && this.canUseLogGradientScale(minVal, maxVal) && value > 0) {
      const logMin = Math.log10(minVal)
      const logMax = Math.log10(maxVal)
      const span = logMax - logMin
      if (span === 0) return 0
      return Math.min(1, Math.max(0, (Math.log10(value) - logMin) / span))
    }
    const span = maxVal - minVal
    if (span === 0) return 0
    return Math.min(1, Math.max(0, (value - minVal) / span))
  }

  renderTrackLists() {
    this.renderTrackListAxis("column")
    this.renderTrackListAxis("row")
  }

  renderTrackListAxis(axis) {
    const listTarget = axis === "column"
      ? (this.hasColTrackListTarget ? this.colTrackListTarget : null)
      : (this.hasRowTrackListTarget ? this.rowTrackListTarget : null)
    const emptyTarget = axis === "column"
      ? (this.hasColTrackListEmptyTarget ? this.colTrackListEmptyTarget : null)
      : (this.hasRowTrackListEmptyTarget ? this.rowTrackListEmptyTarget : null)
    if (!listTarget) return

    const tracks = (axis === "column" ? this.colTracks : this.rowTracks).filter((t) => !t.loading)
    if (emptyTarget) emptyTarget.style.display = tracks.length ? "none" : "block"

    listTarget.innerHTML = tracks.map((track, index) => {
      const ref = axis === "column" ? `c${index + 1}` : `r${index + 1}`
      return `<div class="heatmap-track-row"
                  data-heatmap-axis-param="${axis}"
                  data-heatmap-index-param="${index}"
                  data-action="dragover->heatmap#trackDragOver drop->heatmap#trackDrop">
        <span class="heatmap-track-grip"
              draggable="true"
              title="Drag to reorder"
              aria-label="Drag to reorder"
              data-heatmap-axis-param="${axis}"
              data-heatmap-index-param="${index}"
              data-action="dragstart->heatmap#trackDragStart dragend->heatmap#trackDragEnd">
          <svg viewBox="0 0 8 14" aria-hidden="true">
            <circle cx="2" cy="2" r="1.25" fill="currentColor"/>
            <circle cx="6" cy="2" r="1.25" fill="currentColor"/>
            <circle cx="2" cy="7" r="1.25" fill="currentColor"/>
            <circle cx="6" cy="7" r="1.25" fill="currentColor"/>
            <circle cx="2" cy="12" r="1.25" fill="currentColor"/>
            <circle cx="6" cy="12" r="1.25" fill="currentColor"/>
          </svg>
        </span>
        <span class="heatmap-track-ref">${this.escape(ref)}</span>
        <span class="heatmap-track-name" title="${this.escape(track.name)}">${this.escape(track.name)}</span>
        <button type="button"
                style="display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;padding:0;border:none;background:none;color:#6b7280;cursor:pointer;flex:0 0 auto;"
                title="Edit track"
                aria-label="Edit track"
                data-action="heatmap#openEditTrackModal"
                data-heatmap-id-param="${track.id}"
                data-heatmap-axis-param="${axis}"
                onmouseover="this.style.color='#111827'"
                onmouseout="this.style.color='#6b7280'">
          <i class="fas fa-pen" style="font-size:10px;" aria-hidden="true"></i>
        </button>
      </div>`
    }).join("")
  }

  trackDragStart(event) {
    if (!event.target.closest(".heatmap-track-grip")) {
      event.preventDefault()
      return
    }
    const axis = event.params.axis
    const index = Number(event.params.index)
    if (!axis || !Number.isFinite(index)) return
    this._trackDrag = { axis, index }
    const row = event.target.closest(".heatmap-track-row")
    if (row) row.classList.add("heatmap-track-dragging")
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move"
      event.dataTransfer.setData("text/plain", `${axis}:${index}`)
    }
  }

  trackDragOver(event) {
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move"
    if (!this._trackDrag || this._trackDrag.axis !== event.params.axis) return
    const list = event.currentTarget.parentElement
    if (list) {
      list.querySelectorAll(".heatmap-track-drag-over").forEach((el) => {
        if (el !== event.currentTarget) el.classList.remove("heatmap-track-drag-over")
      })
    }
    event.currentTarget.classList.add("heatmap-track-drag-over")
  }

  trackDrop(event) {
    event.preventDefault()
    event.currentTarget.classList.remove("heatmap-track-drag-over")
    if (!this._trackDrag) return
    const axis = event.params.axis
    const toIndex = Number(event.params.index)
    const fromIndex = this._trackDrag.index
    if (axis !== this._trackDrag.axis || !Number.isFinite(toIndex) || fromIndex === toIndex) return
    this.reorderTrack(axis, fromIndex, toIndex)
  }

  trackDragEnd(event) {
    const row = event.target.closest(".heatmap-track-row")
    if (row) row.classList.remove("heatmap-track-dragging")
    const list = this._trackDrag?.axis === "column"
      ? (this.hasColTrackListTarget ? this.colTrackListTarget : null)
      : (this.hasRowTrackListTarget ? this.rowTrackListTarget : null)
    if (list) {
      list.querySelectorAll(".heatmap-track-drag-over").forEach((el) => el.classList.remove("heatmap-track-drag-over"))
      list.querySelectorAll(".heatmap-track-dragging").forEach((el) => el.classList.remove("heatmap-track-dragging"))
    }
    this._trackDrag = null
  }

  reorderTrack(axis, fromIndex, toIndex) {
    const list = axis === "column" ? this.colTracks : this.rowTracks
    const ready = list.filter((t) => !t.loading)
    if (fromIndex < 0 || toIndex < 0 || fromIndex >= ready.length || toIndex >= ready.length) return

    // Map filtered indices back onto the live list (skip loading placeholders).
    const liveIndexes = []
    list.forEach((t, i) => { if (!t.loading) liveIndexes.push(i) })
    const fromLive = liveIndexes[fromIndex]
    const toLive = liveIndexes[toIndex]
    if (fromLive == null || toLive == null || fromLive === toLive) return
    const [item] = list.splice(fromLive, 1)
    list.splice(toLive, 0, item)
    this.renderTrackLists()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("reorder-track")
  }

  openEditTrackModal(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const id = event?.params?.id
    const axis = event?.params?.axis
    const found = this.findTrackById(id, axis)
    if (!found?.track || found.track.loading) return
    this.editingTrackTarget = { id: found.track.id, axis: found.axis }
    const track = found.track
    const ref = this.trackRefFor(found.axis, track)
    if (this.hasEditTrackModalTitleTarget) {
      this.editTrackModalTitleTarget.textContent = `Edit ${ref}`
    }
    if (this.hasEditTrackModalNameTarget) {
      this.editTrackModalNameTarget.textContent = track.name
    }
    if (this.hasEditTrackTypeTarget) {
      this.editTrackTypeTarget.value = track.type === "numerical" ? "numerical" : "categorical"
      const canNum = this.canUseTrackType(track, "numerical")
      const canCat = this.canUseTrackType(track, "categorical")
      Array.from(this.editTrackTypeTarget.options).forEach((opt) => {
        if (opt.value === "numerical") opt.disabled = !canNum
        if (opt.value === "categorical") opt.disabled = !canCat
      })
    }
    if (this.hasEditTrackDisplayModeTarget) {
      this.editTrackDisplayModeTarget.value = track.displayMode === "barplot" ? "barplot" : "color"
    }
    if (this.hasEditTrackSizeTarget) {
      this.editTrackSizeTarget.value = this.sizeKeyForThickness(track.thickness)
    }
    if (this.hasEditTrackShowLegendTarget) {
      this.editTrackShowLegendTarget.checked = !!track.showLegend
    }
    this.syncEditTrackFormVisibility()
    if (this.hasEditTrackModalTarget) this.editTrackModalTarget.style.display = "flex"
  }

  syncEditTrackFormVisibility() {
    const type = this.hasEditTrackTypeTarget ? this.editTrackTypeTarget.value : "categorical"
    const isNumerical = type === "numerical"
    if (this.hasEditTrackDisplayModeWrapTarget) {
      this.editTrackDisplayModeWrapTarget.style.display = isNumerical ? "block" : "none"
    }
    if (this.hasEditTrackLegendWrapTarget) {
      this.editTrackLegendWrapTarget.style.display = isNumerical ? "none" : "flex"
    }
    if (this.hasEditTrackGradientBtnTarget) {
      this.editTrackGradientBtnTarget.style.display = isNumerical ? "inline-flex" : "none"
    }
    if (this.hasEditTrackTypeHintTarget) {
      if (isNumerical) {
        this.editTrackTypeHintTarget.textContent = "Continuous tracks can be shown as a colored band or a barplot."
      } else {
        this.editTrackTypeHintTarget.textContent = "Categorical tracks are colored by category."
      }
    }
  }

  editTrackFormChanged() {
    this.syncEditTrackFormVisibility()
  }

  closeEditTrackModal() {
    this.editingTrackTarget = null
    if (this.hasEditTrackModalTarget) this.editTrackModalTarget.style.display = "none"
  }

  editTrackModalBackdropClick(event) {
    if (event.target === this.editTrackModalTarget) this.closeEditTrackModal()
  }

  confirmEditTrack() {
    if (!this.editingTrackTarget) return
    const found = this.findTrackById(this.editingTrackTarget.id, this.editingTrackTarget.axis)
    if (!found?.track) {
      this.closeEditTrackModal()
      return
    }
    const track = found.track
    const nextType = this.hasEditTrackTypeTarget ? this.editTrackTypeTarget.value : track.type
    if (nextType !== track.type) this.applyLocalTrackType(track, nextType)

    if (track.type === "numerical") {
      track.displayMode = this.hasEditTrackDisplayModeTarget &&
        this.editTrackDisplayModeTarget.value === "barplot" ? "barplot" : "color"
      this.ensureTrackGradient(track)
    } else {
      track.displayMode = "color"
      track.showLegend = !!(this.hasEditTrackShowLegendTarget && this.editTrackShowLegendTarget.checked)
    }

    const sizeKey = this.hasEditTrackSizeTarget ? this.editTrackSizeTarget.value : "normal"
    track.thickness = this.trackSizePx[sizeKey] || this.layout.trackH

    this.closeEditTrackModal()
    this.renderTrackLists()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("edit-track")
  }

  editTrackRemove() {
    if (!this.editingTrackTarget) return
    const { id, axis } = this.editingTrackTarget
    this.closeEditTrackModal()
    this.removeTrack(id, axis)
  }

  editTrackOpenGradient() {
    if (!this.editingTrackTarget) return
    const { id, axis } = this.editingTrackTarget
    this.confirmEditTrack()
    const found = this.findTrackById(id, axis)
    if (!found?.track || found.track.type !== "numerical") return
    this.openTrackGradientEditor(found.track, found.axis)
  }

  // Kept for any leftover callers; delegates to the below-plot lists.
  renderActiveTracksList() {
    this.renderTrackLists()
  }

  tracksWithInPlotLegends(axis = null) {
    const list = [
      ...this.colTracks.map((t) => ({ ...t, axis: "column" })),
      ...this.rowTracks.map((t) => ({ ...t, axis: "row" }))
    ].filter((t) => {
      if (t.loading) return false
      if (axis && t.axis !== axis) return false
      if (t.type === "numerical") return true
      return !!t.showLegend && Array.isArray(t.categories) && t.categories.length > 0
    })
    return list
  }

  estimateRightLegendWidth() {
    const minW = this.layout.legendWMin
    const maxW = this.layout.legendWMax
    const preferred = Number(this.legendWidthPx) || this.layout.legendW
    return Math.min(maxW, Math.max(minW, Math.round(preferred)))
  }

  syncLegendWidthControls() {
    const width = this.estimateRightLegendWidth()
    if (this.hasLegendWidthSliderTarget) this.legendWidthSliderTarget.value = String(width)
    if (this.hasLegendWidthValueTarget) this.legendWidthValueTarget.textContent = `${width}px`
  }

  estimateRightMargin() {
    const minM = this.layout.rightMarginMin
    const maxM = this.layout.rightMarginMax
    const preferred = Number(this.rightMarginPx)
    const value = Number.isFinite(preferred) ? preferred : this.layout.rightMargin
    return Math.min(maxM, Math.max(minM, Math.round(value)))
  }

  syncRightMarginControls() {
    const margin = this.estimateRightMargin()
    if (this.hasRightMarginSliderTarget) this.rightMarginSliderTarget.value = String(margin)
    if (this.hasRightMarginValueTarget) this.rightMarginValueTarget.textContent = `${margin}px`
  }

  toggleSettingsMenu(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (!this.hasSettingsMenuTarget) return
    const opening = this.settingsMenuTarget.style.display === "none" || !this.settingsMenuTarget.style.display
    if (opening) {
      this.syncLegendWidthControls()
      this.syncRightMarginControls()
      this.settingsMenuTarget.style.display = "block"
      this.ensureSettingsMenuOutsideCloseBound()
    } else {
      this.closeSettingsMenu()
    }
  }

  closeSettingsMenu() {
    if (!this.hasSettingsMenuTarget) return
    this.settingsMenuTarget.style.display = "none"
  }

  ensureSettingsMenuOutsideCloseBound() {
    if (this._settingsOutsideCloseBound) return
    this._settingsOutsideCloseBound = (event) => {
      if (!this.hasSettingsMenuTarget) return
      const menu = this.settingsMenuTarget
      const btn = this.hasSettingsBtnTarget ? this.settingsBtnTarget : null
      if (menu.contains(event.target) || (btn && btn.contains(event.target))) return
      this.closeSettingsMenu()
    }
    document.addEventListener("mousedown", this._settingsOutsideCloseBound)
  }

  legendWidthChanged() {
    if (!this.hasLegendWidthSliderTarget) return
    const value = Number(this.legendWidthSliderTarget.value)
    if (!Number.isFinite(value)) return
    this.legendWidthPx = value
    this.syncLegendWidthControls()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("legend-width")
  }

  rightMarginChanged() {
    if (!this.hasRightMarginSliderTarget) return
    const value = Number(this.rightMarginSliderTarget.value)
    if (!Number.isFinite(value)) return
    this.rightMarginPx = value
    this.syncRightMarginControls()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("right-margin")
  }

  // Build display groups (contiguous leaf ranges) from the dendrogram leaves.
  rebuildDisplay() {
    this.colGroups = this.buildGroups(this.colTree, this.nOrigCols)
    this.rowGroups = this.buildGroups(this.rowTree, this.nOrigRows)

    this.origColToDisplay = this.mapOriginalToDisplay(this.colGroups, this.nOrigCols)
    this.origRowToDisplay = this.mapOriginalToDisplay(this.rowGroups, this.nOrigRows)

    const nDispRows = this.rowGroups.length
    const nDispCols = this.colGroups.length

    // Aggregate columns first, then rows (mean, ignoring NaN).
    const colAgg = new Float32Array(this.nOrigRows * nDispCols)
    for (let r = 0; r < this.nOrigRows; r++) {
      const rowOff = r * this.nOrigCols
      for (let d = 0; d < nDispCols; d++) {
        const [s, e] = this.colGroups[d]
        let sum = 0
        let cnt = 0
        for (let c = s; c <= e; c++) {
          const v = this.baseMatrix[rowOff + c]
          if (!Number.isNaN(v)) { sum += v; cnt++ }
        }
        colAgg[r * nDispCols + d] = cnt > 0 ? sum / cnt : NaN
      }
    }

    const finalMat = new Float32Array(nDispRows * nDispCols)
    for (let dr = 0; dr < nDispRows; dr++) {
      const [s, e] = this.rowGroups[dr]
      for (let d = 0; d < nDispCols; d++) {
        let sum = 0
        let cnt = 0
        for (let r = s; r <= e; r++) {
          const v = colAgg[r * nDispCols + d]
          if (!Number.isNaN(v)) { sum += v; cnt++ }
        }
        finalMat[dr * nDispCols + d] = cnt > 0 ? sum / cnt : NaN
      }
    }

    this.nDispRows = nDispRows
    this.nDispCols = nDispCols
    this.displayMatrix = finalMat
    this.applyActiveColormap()
    this.renderer.setMatrix(
      finalMat,
      nDispRows,
      nDispCols,
      this.vmin,
      this.vmax,
      (v, vmin, vmax) => this.normalizeExpressionValue(v, vmin, vmax)
    )
  }

  buildGroups(tree, nLeaves) {
    const groups = []
    if (!tree || !tree.root) {
      for (let i = 0; i < nLeaves; i++) groups.push([i, i])
      return groups
    }
    const walk = (node) => {
      if (node.leaf) {
        groups.push([node.index, node.index])
        return
      }
      node.children.forEach(walk)
    }
    walk(tree.root)
    groups.sort((a, b) => a[0] - b[0])
    return groups
  }

  mapOriginalToDisplay(groups, n) {
    const map = new Int32Array(n)
    groups.forEach((g, gi) => {
      for (let i = g[0]; i <= g[1]; i++) map[i] = gi
    })
    return map
  }

  resetView(rerender = true) {
    if (rerender) this.rebuildDisplay()
    this.view = {
      colStart: 0,
      colEnd: this.nDispCols,
      rowStart: 0,
      rowEnd: this.nDispRows
    }
    if (rerender) this.render()
  }

  reset() {
    this.showRowTree = true
    this.showColTree = true
    this.showLabels = true
    this.syncToggleButtons()
    this.resetView(true)
    this.handleResize()
  }

  toggleRowTree() {
    this.showRowTree = !this.showRowTree
    this.syncToggleButtons()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("toggle-row-tree")
  }

  toggleColTree() {
    this.showColTree = !this.showColTree
    this.syncToggleButtons()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("toggle-col-tree")
  }

  toggleLabels() {
    this.showLabels = !this.showLabels
    this.syncToggleButtons()
    this.handleResize()
    this.persistCurrentCheckpointOnServer("toggle-labels")
  }

  syncToggleButtons() {
    this.applyToggleState(this.hasColTreeToggleTarget ? this.colTreeToggleTarget : null,
      this.hasColTreeStateTarget ? this.colTreeStateTarget : null,
      this.showColTree)
    this.applyToggleState(this.hasRowTreeToggleTarget ? this.rowTreeToggleTarget : null,
      this.hasRowTreeStateTarget ? this.rowTreeStateTarget : null,
      this.showRowTree)
    this.applyToggleState(this.hasLabelsToggleTarget ? this.labelsToggleTarget : null,
      this.hasLabelsStateTarget ? this.labelsStateTarget : null,
      this.showLabels)
  }

  applyToggleState(button, stateLabel, isOn) {
    if (button) button.setAttribute("aria-pressed", isOn ? "true" : "false")
    if (stateLabel) stateLabel.textContent = isOn ? "On" : "Off"
  }

  handleResize() {
    if (!this.renderer) return
    if (this.isMobileHeatmapLayout()) {
      this.updateMobileHeatmapChromeHeight()
    }
    const container = this.element.querySelector(".heatmap-canvas-area")
    if (!container) return
    const w = container.clientWidth
    const h = container.clientHeight
    if (w <= 0 || h <= 0) return

    this.containerW = w
    this.containerH = h
    this.computeLayout()

    // Size and place the WebGL canvas over the matrix rectangle.
    const gl = this.webglTarget
    gl.style.position = "absolute"
    gl.style.left = this.mx + "px"
    gl.style.top = this.my + "px"
    gl.style.width = this.mw + "px"
    gl.style.height = this.mh + "px"
    const maxBufferDim = this.renderer?.maxTextureSize
      ? Math.max(256, this.renderer.maxTextureSize)
      : 8192
    gl.width = Math.max(1, Math.min(maxBufferDim, Math.round(this.mw * this.dpr)))
    gl.height = Math.max(1, Math.min(maxBufferDim, Math.round(this.mh * this.dpr)))

    const ov = this.overlayTarget
    ov.style.position = "absolute"
    ov.style.left = "0px"
    ov.style.top = "0px"
    ov.style.width = w + "px"
    ov.style.height = h + "px"
    ov.style.zIndex = "2"
    ov.style.pointerEvents = "auto"
    ov.style.touchAction = "none"
    ov.width = Math.max(1, Math.min(maxBufferDim, Math.round(w * this.dpr)))
    ov.height = Math.max(1, Math.min(maxBufferDim, Math.round(h * this.dpr)))

    this.render()
  }

  computeLayout() {
    const L = this.layout
    const mobile = this.isMobileHeatmapLayout()
    const colTracks = this.colTracks.filter((t) => !t.loading)
    const rowTracks = this.rowTracks.filter((t) => !t.loading)

    const colTreeMax = mobile ? 48 : L.colTreeH
    const rowTreeMax = mobile ? 48 : L.rowTreeW
    const colTreeH = this.showColTree && this.colTree ? colTreeMax : 0
    const rowTreeW = this.showRowTree && this.rowTree ? rowTreeMax : 0

    this.colTrackOffsets = []
    let colTracksH = 0
    colTracks.forEach((track, ti) => {
      this.colTrackOffsets.push(colTracksH)
      colTracksH += (track.thickness || L.trackH)
      if (ti < colTracks.length - 1) colTracksH += L.trackGap
    })

    this.rowTrackOffsets = []
    let rowTracksW = 0
    rowTracks.forEach((track, ti) => {
      this.rowTrackOffsets.push(rowTracksW)
      rowTracksW += (track.thickness || L.trackW)
      if (ti < rowTracks.length - 1) rowTracksW += L.trackGap
    })

    // Track bands only — + buttons and c/r refs are overlays and must not open a gap
    // between tracks and the heatmap matrix.
    this.leftTracksW = rowTracksW
    this.topTracksH = colTracksH
    this.trackRefW = colTracks.length ? L.trackRefW : 0
    this.trackRefH = rowTracks.length ? L.trackRefH : 0

    this.mx = L.pad + rowTreeW + this.leftTracksW
    this.my = L.pad + colTreeH + this.topTracksH
    this.colTreeH = colTreeH
    this.rowTreeW = rowTreeW
    this.rightLegendW = mobile ? 0 : this.estimateRightLegendWidth()
    this.rightMargin = mobile ? 0 : this.estimateRightMargin()
    this.labelW = this.showLabels ? (mobile ? Math.min(L.rowLabelW, 36) : L.rowLabelW) : 0

    const labelH = this.showLabels ? (mobile ? Math.min(L.colLabelH, 40) : L.colLabelH) : 0
    // Right side: [matrix][gene labels][rightMargin][legend][pad]
    this.mw = Math.max(20, this.containerW - this.mx - this.labelW - this.rightMargin - this.rightLegendW - L.pad)
    this.mh = Math.max(20, this.containerH - this.my - labelH - L.pad)
    this.legendLeft = this.mx + this.mw + this.labelW + this.rightMargin
    this.positionAddTrackButtons()
  }

  positionAddTrackButtons() {
  // Place add-track controls on the dendrogram corners, clear of heatmap cells, tracks, and refs.
    const size = 22
    const gap = 4

    // Cell metadata track control: right of the horizontal (column) tree, bottom of the tree band.
    const colTreeBottom = this.layout.pad + this.colTreeH
    const colLeft = this.mx + this.mw + gap
    const colTop = this.colTreeH > 0
      ? colTreeBottom - size - gap
      : Math.max(2, this.my - size - gap)

    // Gene metadata track control: above the right side of the vertical (row) tree.
    const rowTreeRight = this.layout.pad + this.rowTreeW
    const rowLeft = this.rowTreeW > 0
      ? rowTreeRight - size
      : Math.max(2, this.mx - this.leftTracksW - size - gap)
    const rowTop = Math.max(2, this.my - size - gap)

    if (this.hasAddColTrackBtnTarget) {
      const btn = this.addColTrackBtnTarget
      btn.style.display = "flex"
      btn.style.left = `${Math.max(2, Math.min(colLeft, this.containerW - size - 2))}px`
      btn.style.top = `${Math.max(2, colTop)}px`
    }

    if (this.hasAddRowTrackBtnTarget) {
      const btn = this.addRowTrackBtnTarget
      btn.style.display = "flex"
      btn.style.left = `${Math.max(2, Math.min(rowLeft, this.containerW - size - 2))}px`
      btn.style.top = `${Math.max(2, rowTop)}px`
    }
  }

  exportSvg() {
    if (!this.renderer || !this.hasWebglTarget || !this.hasOverlayTarget) return

    this.render()

    const w = this.containerW
    const h = this.containerH
    const dpr = this.dpr
    const composite = document.createElement("canvas")
    composite.width = Math.max(1, Math.round(w * dpr))
    composite.height = Math.max(1, Math.round(h * dpr))
    const ctx = composite.getContext("2d")
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.fillStyle = "#ffffff"
    ctx.fillRect(0, 0, w, h)
    ctx.drawImage(this.webglTarget, this.mx, this.my, this.mw, this.mh)
    ctx.drawImage(this.overlayTarget, 0, 0, w, h)

    const png = composite.toDataURL("image/png")
    const svg = [
      '<?xml version="1.0" encoding="UTF-8"?>',
      `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">`,
      `<image width="${w}" height="${h}" xlink:href="${png}"/>`,
      "</svg>"
    ].join("")

    const blob = new Blob([svg], { type: "image/svg+xml;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")
    link.href = url
    link.download = `heatmap_${this.runIdValue || "export"}.svg`
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    URL.revokeObjectURL(url)
  }

  bindEvents() {
    const ov = this.overlayTarget
    if (!ov || this._heatmapPointerEventsBound) return
    this._heatmapPointerEventsBound = true

    ov.style.touchAction = "none"
    this._activePointerId = null
    this._lastHeatmapTap = null

    this._onWheel = (e) => this.onWheel(e)
    this._onPointerDown = (e) => this.onPointerDown(e)
    this._onPointerMove = (e) => this.onPointerMove(e)
    this._onPointerUp = (e) => this.onPointerUp(e)
    this._onClick = (e) => this.onClick(e)
    this._onDblClick = (e) => this.onDblClick(e)
    this._onPointerLeave = () => {
      if (!this.selecting && !this.dragging) this.hideTooltip()
    }

    ov.addEventListener("wheel", this._onWheel, { passive: false })
    ov.addEventListener("pointerdown", this._onPointerDown)
    window.addEventListener("pointermove", this._onPointerMove)
    window.addEventListener("pointerup", this._onPointerUp)
    window.addEventListener("pointercancel", this._onPointerUp)
    ov.addEventListener("click", this._onClick)
    ov.addEventListener("dblclick", this._onDblClick)
    ov.addEventListener("pointerleave", this._onPointerLeave)
  }

  unbindEvents() {
    const ov = this.overlayTarget
    if (!this._heatmapPointerEventsBound) return
    this._heatmapPointerEventsBound = false

    if (ov && this._onWheel) ov.removeEventListener("wheel", this._onWheel)
    if (ov && this._onPointerDown) ov.removeEventListener("pointerdown", this._onPointerDown)
    if (this._onPointerMove) window.removeEventListener("pointermove", this._onPointerMove)
    if (this._onPointerUp) {
      window.removeEventListener("pointerup", this._onPointerUp)
      window.removeEventListener("pointercancel", this._onPointerUp)
    }
    if (ov && this._onClick) ov.removeEventListener("click", this._onClick)
    if (ov && this._onDblClick) ov.removeEventListener("dblclick", this._onDblClick)
    if (ov && this._onPointerLeave) ov.removeEventListener("pointerleave", this._onPointerLeave)

    this._onWheel = null
    this._onPointerDown = null
    this._onPointerMove = null
    this._onPointerUp = null
    this._onClick = null
    this._onDblClick = null
    this._onPointerLeave = null
    this._activePointerId = null
  }

  localPoint(e) {
    const rect = this.overlayTarget.getBoundingClientRect()
    const clientX = Number.isFinite(e.clientX)
      ? e.clientX
      : (e.touches && e.touches[0] ? e.touches[0].clientX : 0)
    const clientY = Number.isFinite(e.clientY)
      ? e.clientY
      : (e.touches && e.touches[0] ? e.touches[0].clientY : 0)
    return { x: clientX - rect.left, y: clientY - rect.top }
  }

  inMatrix(p) {
    return p.x >= this.mx && p.x <= this.mx + this.mw && p.y >= this.my && p.y <= this.my + this.mh
  }

  colForX(x) {
    const v = this.view
    return v.colStart + ((x - this.mx) / this.mw) * (v.colEnd - v.colStart)
  }

  rowForY(y) {
    const v = this.view
    return v.rowStart + ((y - this.my) / this.mh) * (v.rowEnd - v.rowStart)
  }

  xForCol(c) {
    const v = this.view
    return this.mx + ((c - v.colStart) / (v.colEnd - v.colStart)) * this.mw
  }

  yForRow(r) {
    const v = this.view
    return this.my + ((r - v.rowStart) / (v.rowEnd - v.rowStart)) * this.mh
  }

  setPanMode(event) {
    if (event) event.preventDefault()
    this.interactionMode = "pan"
    this.selecting = false
    this.selectionRect = null
    this.syncInteractionModeButtons()
    this.drawOverlay()
  }

  setSelectMode(event) {
    if (event) event.preventDefault()
    this.interactionMode = "select"
    this.dragging = false
    this.dragStart = null
    this.syncInteractionModeButtons()
    this.drawOverlay()
  }

  syncInteractionModeButtons() {
    const isPan = this.interactionMode !== "select"
    if (this.hasPanModeBtnTarget) {
      this.panModeBtnTarget.setAttribute("aria-pressed", isPan ? "true" : "false")
    }
    if (this.hasSelectModeBtnTarget) {
      this.selectModeBtnTarget.setAttribute("aria-pressed", isPan ? "false" : "true")
    }
    if (this.hasOverlayTarget) {
      if (this.interactionMode === "select") {
        this.overlayTarget.style.cursor = "crosshair"
      } else {
        this.overlayTarget.style.cursor = "grab"
      }
    }
    if (this.hasControlInstructionsTarget) {
      this.controlInstructionsTarget.textContent = isPan
        ? "Drag to pan, Shift+scroll to zoom. Double-click to clear selection."
        : "Drag a rectangle to select genes (rows) and cells (columns). Selections accumulate. Double-click to clear."
    }
  }

  initializePanelLayout() {
    this.teardownPanelLayout()
    const leftPanel = this.element.querySelector("#heatmap-left-panel")
    const rightPanel = this.element.querySelector("#heatmap-right-panel")
    const leftResizer = this.element.querySelector("#heatmap-left-resizer")
    const rightResizer = this.element.querySelector("#heatmap-right-resizer")
    if (!leftPanel || !rightPanel || !leftResizer || !rightResizer) return

    this._panelResizeState = { left: false, right: false, startX: 0, startLeft: 0, startRight: 0 }

    this._onPanelResizeMove = (e) => {
      const state = this._panelResizeState
      if (!state) return
      if (state.left) {
        const deltaX = e.clientX - state.startX
        leftPanel.style.width = `${Math.max(200, Math.min(560, state.startLeft + deltaX))}px`
        this.handleResize()
      } else if (state.right) {
        const deltaX = e.clientX - state.startX
        rightPanel.style.width = `${Math.max(200, Math.min(560, state.startRight - deltaX))}px`
        this.handleResize()
      }
    }

    this._onPanelResizeUp = () => {
      const state = this._panelResizeState
      if (!state || (!state.left && !state.right)) return
      state.left = false
      state.right = false
      document.body.style.cursor = ""
      document.body.style.userSelect = ""
      this.handleResize()
    }

    this._onLeftResizerDown = (e) => {
      this._panelResizeState.left = true
      this._panelResizeState.right = false
      this._panelResizeState.startX = e.clientX
      this._panelResizeState.startLeft = leftPanel.offsetWidth
      document.body.style.cursor = "col-resize"
      document.body.style.userSelect = "none"
      e.preventDefault()
    }

    this._onRightResizerDown = (e) => {
      this._panelResizeState.right = true
      this._panelResizeState.left = false
      this._panelResizeState.startX = e.clientX
      this._panelResizeState.startRight = rightPanel.offsetWidth
      document.body.style.cursor = "col-resize"
      document.body.style.userSelect = "none"
      e.preventDefault()
    }

    leftResizer.addEventListener("mousedown", this._onLeftResizerDown)
    rightResizer.addEventListener("mousedown", this._onRightResizerDown)
    document.addEventListener("mousemove", this._onPanelResizeMove)
    document.addEventListener("mouseup", this._onPanelResizeUp)

    this._boundHorizontalCleanups = []
    this._boundHorizontalCleanups.push(
      this.bindHorizontalDivider(
        this.element.querySelector("#heatmap-left-divider"),
        this.element.querySelector("#heatmap-cell-tracks-panel"),
        this.element.querySelector("#heatmap-gene-tracks-panel")
      )
    )
    this._boundHorizontalCleanups.push(
      this.bindHorizontalDivider(
        this.element.querySelector("#heatmap-right-divider"),
        this.element.querySelector("#heatmap-genes-panel"),
        this.element.querySelector("#heatmap-cells-panel")
      )
    )
  }

  bindHorizontalDivider(divider, topPanel, bottomPanel) {
    if (!divider || !topPanel || !bottomPanel) return null
    const container = divider.parentElement
    if (!container) return null
    const minPanelHeight = 100
    let dragging = false
    let startY = 0
    let startHeight = 0

    const onDown = (e) => {
      dragging = true
      startY = e.clientY
      startHeight = topPanel.offsetHeight
      document.body.style.cursor = "row-resize"
      document.body.style.userSelect = "none"
      divider.style.backgroundColor = "#6B7280"
      e.preventDefault()
    }
    const onMove = (e) => {
      if (!dragging) return
      const containerHeight = container.offsetHeight - divider.offsetHeight
      const next = Math.max(minPanelHeight, Math.min(startHeight + (e.clientY - startY), containerHeight - minPanelHeight))
      topPanel.style.height = `${(next / containerHeight) * 100}%`
      topPanel.style.flex = "none"
    }
    const onUp = () => {
      if (!dragging) return
      dragging = false
      document.body.style.cursor = ""
      document.body.style.userSelect = ""
      divider.style.backgroundColor = ""
    }

    divider.addEventListener("mousedown", onDown)
    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
    return () => {
      divider.removeEventListener("mousedown", onDown)
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
    }
  }

  teardownPanelLayout() {
    const leftResizer = this.element.querySelector("#heatmap-left-resizer")
    const rightResizer = this.element.querySelector("#heatmap-right-resizer")
    if (leftResizer && this._onLeftResizerDown) {
      leftResizer.removeEventListener("mousedown", this._onLeftResizerDown)
    }
    if (rightResizer && this._onRightResizerDown) {
      rightResizer.removeEventListener("mousedown", this._onRightResizerDown)
    }
    if (this._onPanelResizeMove) {
      document.removeEventListener("mousemove", this._onPanelResizeMove)
    }
    if (this._onPanelResizeUp) {
      document.removeEventListener("mouseup", this._onPanelResizeUp)
    }
    if (Array.isArray(this._boundHorizontalCleanups)) {
      this._boundHorizontalCleanups.forEach((fn) => { if (typeof fn === "function") fn() })
    }
    this._boundHorizontalCleanups = []
    this._onLeftResizerDown = null
    this._onRightResizerDown = null
    this._onPanelResizeMove = null
    this._onPanelResizeUp = null
    this._panelResizeState = null
  }

  isMobileHeatmapLayout() {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
      return false
    }
    if (!this.element?.querySelector?.("#heatmap-mobile-panel-selector")) {
      return false
    }
    return window.matchMedia("(max-width: 1023px)").matches
  }

  initializeMobileHeatmapLayout() {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
      return
    }
    if (!this.element?.querySelector?.("#heatmap-mobile-panel-selector")) {
      return
    }

    this.mobileHeatmapMediaQuery = window.matchMedia("(max-width: 1023px)")
    this.boundSyncMobileHeatmapLayout = () => this.syncMobileHeatmapLayout()
    this.boundMobileHeatmapEscape = (event) => {
      if (event.key !== "Escape") return
      if (!this.element?.dataset?.mobilePanel) return
      this.closeMobilePanel()
    }

    if (typeof this.mobileHeatmapMediaQuery.addEventListener === "function") {
      this.mobileHeatmapMediaQuery.addEventListener("change", this.boundSyncMobileHeatmapLayout)
    } else if (typeof this.mobileHeatmapMediaQuery.addListener === "function") {
      this.mobileHeatmapMediaQuery.addListener(this.boundSyncMobileHeatmapLayout)
    }

    document.addEventListener("keydown", this.boundMobileHeatmapEscape)
    this.bindMobileLegendInteractions()
    this.syncMobileHeatmapLayout({ redraw: false })
  }

  teardownMobileHeatmapLayout() {
    if (this.mobileHeatmapMediaQuery && this.boundSyncMobileHeatmapLayout) {
      if (typeof this.mobileHeatmapMediaQuery.removeEventListener === "function") {
        this.mobileHeatmapMediaQuery.removeEventListener("change", this.boundSyncMobileHeatmapLayout)
      } else if (typeof this.mobileHeatmapMediaQuery.removeListener === "function") {
        this.mobileHeatmapMediaQuery.removeListener(this.boundSyncMobileHeatmapLayout)
      }
    }
    this.mobileHeatmapMediaQuery = null
    this.boundSyncMobileHeatmapLayout = null

    if (this.boundMobileHeatmapEscape) {
      document.removeEventListener("keydown", this.boundMobileHeatmapEscape)
      this.boundMobileHeatmapEscape = null
    }

    if (this._mobileSplitLayoutTimer) {
      window.clearTimeout(this._mobileSplitLayoutTimer)
      this._mobileSplitLayoutTimer = null
    }

    this.unbindMobileLegendInteractions()
    this.closeMobilePanel({ redraw: false })
    document.body.classList.remove("heatmap-mobile-panel-open")
    this.element?.classList?.remove("heatmap-mobile-layout")
    this._mobilePlotHeightLock = null
    this._mobileStableHeaderHeight = null
    this._mobileStableToolbarHeight = null
    this._pendingMobilePanel = null
    this._mobileLegendHit = null
    this.hideMobilePanelLoading()
    this.element?.style?.removeProperty?.("--heatmap-mobile-panel-top")
    this.element?.style?.removeProperty?.("--heatmap-mobile-panel-region-height")
    this.element?.style?.removeProperty?.("--heatmap-mobile-plot-height")
    this.element?.style?.removeProperty?.("--heatmap-mobile-plot-footer-height")
  }

  syncMobileHeatmapLayout({ redraw = true } = {}) {
    if (!this.element) return

    const isMobile = this.isMobileHeatmapLayout()
    this.element.classList.toggle("heatmap-mobile-layout", isMobile)

    if (!isMobile && this.element.dataset.mobilePanel) {
      this.closeMobilePanel({ redraw: false })
    }

    this.updateMobileHeatmapChromeHeight()
    this.updateMobilePanelSelectorState()

    if (redraw && this.renderer) {
      requestAnimationFrame(() => this.handleResize())
    }
  }

  updateMobileHeatmapChromeHeight() {
    if (!this.element || !this.isMobileHeatmapLayout()) {
      document.body.classList.remove("heatmap-mobile-panel-open")
      this._mobilePlotHeightLock = null
      this._mobileStableHeaderHeight = null
      this._mobileStableToolbarHeight = null
      this._pendingMobilePanel = null
      this.hideMobilePanelLoading()
      this.element?.style?.removeProperty?.("--heatmap-mobile-panel-top")
      this.element?.style?.removeProperty?.("--heatmap-mobile-panel-region-height")
      this.element?.style?.removeProperty?.("--heatmap-mobile-plot-height")
      this.element?.style?.removeProperty?.("--heatmap-mobile-plot-footer-height")
      return
    }

    const header = document.getElementById("project-page-header")
    const pageHeader = document.getElementById("heatmap-page-header")
    const toolbar = this.element.querySelector(".heatmap-toolbar")
    const selector = this.element.querySelector("#heatmap-mobile-panel-selector")
    const panelOpen = !!this.element.dataset.mobilePanel

    if (!panelOpen) {
      this._mobileStableHeaderHeight =
        (header?.getBoundingClientRect?.().height || 0) +
        (pageHeader?.getBoundingClientRect?.().height || 0) || 64
      this._mobileStableToolbarHeight = toolbar?.getBoundingClientRect?.().height || 0
    }

    document.body.classList.toggle("heatmap-mobile-panel-open", panelOpen)

    const headerHeight = this._mobileStableHeaderHeight || 64
    const toolbarHeight = this._mobileStableToolbarHeight || 0
    const selectorHeight = selector?.getBoundingClientRect?.().height || 0
    // Match visualization: fixed footer band so plot docking stays stable.
    const footerHeight = 36
    const stableChromeHeight = Math.ceil(headerHeight + toolbarHeight + selectorHeight + footerHeight)

    const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0
    // Keep a solid band above the docked plot for mobile panels (and avoid a
    // tall empty strip below the heatmap).
    const minPanelRegion = Math.max(200, Math.round(viewportHeight * 0.4))

    // Recalculate only while panels are closed so opening one does not jump the canvas.
    if (!panelOpen || !this._mobilePlotHeightLock) {
      this._mobilePlotHeightLock = Math.max(
        160,
        Math.round(viewportHeight - stableChromeHeight - minPanelRegion)
      )
    }

    this.element.style.setProperty("--heatmap-mobile-plot-height", `${this._mobilePlotHeightLock}px`)
    this.element.style.setProperty("--heatmap-mobile-plot-footer-height", `${footerHeight}px`)

    if (!panelOpen) {
      this.element.style.removeProperty("--heatmap-mobile-panel-top")
      this.element.style.removeProperty("--heatmap-mobile-panel-region-height")
      return
    }

    const selectorBottom = selector?.getBoundingClientRect?.().bottom
    const panelTop = Math.ceil(
      Number.isFinite(selectorBottom) && selectorBottom > 0
        ? selectorBottom
        : selectorHeight
    )
    const availableBelowChrome = Math.max(180, viewportHeight - panelTop)
    const plotReserve = (this._mobilePlotHeightLock || 200) + footerHeight
    const panelRegionHeight = Math.max(160, availableBelowChrome - plotReserve)

    this.element.style.setProperty("--heatmap-mobile-panel-top", `${panelTop}px`)
    this.element.style.setProperty("--heatmap-mobile-panel-region-height", `${panelRegionHeight}px`)
  }

  scheduleMobileSplitLayoutRefresh({ redraw = false } = {}) {
    if (this._mobileSplitLayoutTimer) {
      window.clearTimeout(this._mobileSplitLayoutTimer)
      this._mobileSplitLayoutTimer = null
    }

    this._mobileSplitLayoutTimer = window.setTimeout(() => {
      this._mobileSplitLayoutTimer = null
      if (!this.element || !this.isMobileHeatmapLayout()) return
      this.updateMobileHeatmapChromeHeight()
      if (redraw && this.renderer) {
        this.handleResize()
      } else if (this.element.dataset.mobilePanel === "legend") {
        this.drawMobileLegend()
      }
    }, 0)
  }

  openMobilePanel(eventOrKey) {
    if (eventOrKey?.type === "pointerdown") {
      if (eventOrKey.pointerType === "mouse" && eventOrKey.button !== 0) return
      eventOrKey.preventDefault()
      eventOrKey.stopPropagation?.()
    } else if (eventOrKey?.preventDefault) {
      eventOrKey.preventDefault()
      eventOrKey.stopPropagation?.()
    }

    const panelKey = typeof eventOrKey === "string"
      ? eventOrKey
      : (eventOrKey?.currentTarget?.dataset?.mobilePanel || eventOrKey?.target?.dataset?.mobilePanel || "")
    const normalizedKey = String(panelKey || "").trim()
    const allowed = new Set(["cell-tracks", "gene-tracks", "genes", "cells", "gene-sets", "legend"])
    if (!allowed.has(normalizedKey)) return

    if (!this.isMobileHeatmapLayout()) {
      if (normalizedKey === "cells" || normalizedKey === "gene-sets") {
        this.setSelectionTab(normalizedKey === "gene-sets" ? "gene-sets" : "cells")
      }
      return
    }

    const previousPanel = this.element.dataset.mobilePanel || this._pendingMobilePanel || ""
    const isUserGesture = typeof eventOrKey !== "string" && !!eventOrKey?.type

    if (isUserGesture && previousPanel === normalizedKey) {
      this.closeMobilePanel({ redraw: false })
      return
    }

    const wasClosed = !previousPanel
    this._mobilePanelSwitchToken = (this._mobilePanelSwitchToken || 0) + 1
    const switchToken = this._mobilePanelSwitchToken
    this._pendingMobilePanel = normalizedKey

    this.updateMobilePanelSelectorState(normalizedKey, { loadingKey: normalizedKey })
    this.ensureMobilePanelRegionVars()
    this.showMobilePanelLoading()

    const revealPanel = () => {
      if (switchToken !== this._mobilePanelSwitchToken) return

      // Measure closed-layout plot height before hiding toolbar/header.
      if (wasClosed) {
        this.updateMobileHeatmapChromeHeight()
      }

      this.element.dataset.mobilePanel = normalizedKey
      this._pendingMobilePanel = null
      this.updateMobilePanelSelectorState(normalizedKey, { loadingKey: normalizedKey })

      if (normalizedKey === "cells" || normalizedKey === "gene-sets") {
        this.setSelectionTab(normalizedKey === "gene-sets" ? "gene-sets" : "cells")
      }

      if (wasClosed) {
        this.updateMobileHeatmapChromeHeight()
      }

      const finishLoading = () => {
        if (switchToken !== this._mobilePanelSwitchToken) return
        if (normalizedKey === "legend") {
          this.drawMobileLegend()
        }
        window.setTimeout(() => {
          if (switchToken !== this._mobilePanelSwitchToken) return
          this.hideMobilePanelLoading()
          this.updateMobilePanelSelectorState(normalizedKey)
        }, 50)
      }

      requestAnimationFrame(() => {
        requestAnimationFrame(finishLoading)
      })
    }

    window.setTimeout(revealPanel, 0)
  }

  closeMobilePanel(eventOrOptions) {
    if (eventOrOptions?.preventDefault) {
      eventOrOptions.preventDefault()
      eventOrOptions.stopPropagation?.()
    }

    const redraw = eventOrOptions?.redraw === true
    this._mobilePanelSwitchToken = (this._mobilePanelSwitchToken || 0) + 1
    this._pendingMobilePanel = null
    this.hideMobilePanelLoading()

    if (!this.element?.dataset?.mobilePanel) {
      this.updateMobilePanelSelectorState("")
      return
    }

    delete this.element.dataset.mobilePanel
    document.body.classList.remove("heatmap-mobile-panel-open")
    this.updateMobilePanelSelectorState("")
    this.updateMobileHeatmapChromeHeight()

    if (redraw) {
      this.scheduleMobileSplitLayoutRefresh({ redraw: true })
    }
  }

  ensureMobilePanelRegionVars() {
    if (!this.element) return
    const hasTop = this.element.style.getPropertyValue("--heatmap-mobile-panel-top")
    const hasHeight = this.element.style.getPropertyValue("--heatmap-mobile-panel-region-height")
    if (hasTop && hasHeight) return

    const selector = this.element.querySelector("#heatmap-mobile-panel-selector")
    const selectorBottom = selector?.getBoundingClientRect?.().bottom
    const panelTop = Math.ceil(
      Number.isFinite(selectorBottom) && selectorBottom > 0
        ? selectorBottom
        : (selector?.getBoundingClientRect?.().height || 40)
    )
    const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0
    const plotReserve = (this._mobilePlotHeightLock || 200) + 36
    const panelRegionHeight = Math.max(160, viewportHeight - panelTop - plotReserve)

    this.element.style.setProperty("--heatmap-mobile-panel-top", `${panelTop}px`)
    this.element.style.setProperty("--heatmap-mobile-panel-region-height", `${panelRegionHeight}px`)
  }

  showMobilePanelLoading() {
    const el = this.element?.querySelector?.("#heatmap-mobile-panel-loading")
    if (!el) return
    el.classList.add("is-visible")
    el.setAttribute("aria-busy", "true")
  }

  hideMobilePanelLoading() {
    const el = this.element?.querySelector?.("#heatmap-mobile-panel-loading")
    if (!el) return
    el.classList.remove("is-visible")
    el.setAttribute("aria-busy", "false")
  }

  updateMobilePanelSelectorState(activePanel = null, { loadingKey = null } = {}) {
    const resolvedActive = activePanel != null
      ? String(activePanel)
      : (this._pendingMobilePanel || this.element?.dataset?.mobilePanel || "")
    const buttons = this.element?.querySelectorAll?.("#heatmap-mobile-panel-selector [data-mobile-panel]") || []
    buttons.forEach((button) => {
      const key = button.dataset.mobilePanel || ""
      const isActive = key === resolvedActive
      const isLoading = loadingKey != null && key === loadingKey
      button.setAttribute("aria-pressed", isActive ? "true" : "false")
      button.classList.toggle("is-loading", isLoading)

      const existingSpinner = button.querySelector(".heatmap-mobile-panel-btn-spinner")
      if (isLoading && !existingSpinner) {
        const spinner = document.createElement("span")
        spinner.className = "heatmap-mobile-panel-btn-spinner"
        spinner.innerHTML = '<i class="fas fa-spinner fa-spin" aria-hidden="true"></i>'
        button.appendChild(spinner)
      } else if (!isLoading && existingSpinner) {
        existingSpinner.remove()
      }
    })
  }

  bindMobileLegendInteractions() {
    if (!this.hasMobileLegendTarget) return
    this.unbindMobileLegendInteractions()
    this._onMobileLegendClick = (e) => this.onMobileLegendClick(e)
    this._onMobileLegendMove = (e) => this.onMobileLegendMove(e)
    this._onMobileLegendLeave = () => this.onMobileLegendLeave()
    this.mobileLegendTarget.addEventListener("click", this._onMobileLegendClick)
    this.mobileLegendTarget.addEventListener("pointermove", this._onMobileLegendMove)
    this.mobileLegendTarget.addEventListener("pointerleave", this._onMobileLegendLeave)
  }

  unbindMobileLegendInteractions() {
    if (!this.hasMobileLegendTarget) return
    if (this._onMobileLegendClick) {
      this.mobileLegendTarget.removeEventListener("click", this._onMobileLegendClick)
    }
    if (this._onMobileLegendMove) {
      this.mobileLegendTarget.removeEventListener("pointermove", this._onMobileLegendMove)
    }
    if (this._onMobileLegendLeave) {
      this.mobileLegendTarget.removeEventListener("pointerleave", this._onMobileLegendLeave)
    }
    this._onMobileLegendClick = null
    this._onMobileLegendMove = null
    this._onMobileLegendLeave = null
  }

  mobileLegendLocalPoint(e) {
    const rect = this.mobileLegendTarget.getBoundingClientRect()
    return { x: e.clientX - rect.left, y: e.clientY - rect.top }
  }

  hitTestMobileLegend(p) {
    const store = this._mobileLegendHit
    if (!store) return null
    const b = store.legendBounds
    if (b && p.x >= b.x && p.x <= b.x + b.width && p.y >= b.y && p.y <= b.y + b.height) {
      return { type: "expression" }
    }
    for (const entry of (store.trackLegendBounds || [])) {
      const bb = entry.bounds
      if (p.x >= bb.x && p.x <= bb.x + bb.width && p.y >= bb.y && p.y <= bb.y + bb.height) {
        return { type: "track", track: entry.track, axis: entry.axis }
      }
    }
    return null
  }

  onMobileLegendClick(e) {
    const p = this.mobileLegendLocalPoint(e)
    const legendHit = this.hitTestMobileLegend(p)
    if (!legendHit) return
    if (legendHit.type === "expression") this.openExpressionGradientEditor()
    else this.openTrackGradientEditor(legendHit.track, legendHit.axis)
  }

  onMobileLegendMove(e) {
    const p = this.mobileLegendLocalPoint(e)
    const hoveringTarget = this.hitTestMobileLegend(p)
    const hoveringLegend = !!hoveringTarget
    const hoverKey = hoveringTarget?.type === "track"
      ? `${hoveringTarget.axis}:${hoveringTarget.track.id}`
      : (hoveringTarget ? "expression" : null)
    if (hoveringLegend !== this.isHoveringLegend || hoverKey !== this.hoveringTrackLegendKey) {
      this.isHoveringLegend = hoveringLegend
      this.hoveringTrackLegendKey = hoverKey
      this.mobileLegendTarget.style.cursor = hoveringLegend ? "pointer" : "default"
      this.drawMobileLegend()
    }
  }

  onMobileLegendLeave() {
    if (!this.isHoveringLegend && !this.hoveringTrackLegendKey) return
    this.isHoveringLegend = false
    this.hoveringTrackLegendKey = null
    if (this.hasMobileLegendTarget) this.mobileLegendTarget.style.cursor = "default"
    this.drawMobileLegend()
  }

  estimateMobileLegendHeight() {
    let height = 72
    const tracks = this.tracksWithInPlotLegends()
    if (tracks.length) height += 24
    tracks.forEach((track) => {
      height += 18
      if (track.type === "numerical") {
        height += 22
      } else {
        const cats = Array.isArray(track.categories) ? track.categories.length : 0
        height += Math.max(1, Math.ceil(cats / 2)) * 16 + 8
      }
    })
    return Math.max(120, height + 24)
  }

  drawMobileLegend() {
    if (!this.hasMobileLegendTarget) return
    if (!this.isMobileHeatmapLayout()) return

    const canvas = this.mobileLegendTarget
    const body = canvas.closest(".heatmap-legend-panel-body") || canvas.parentElement
    const cssW = Math.max(160, Math.floor(body?.clientWidth || canvas.clientWidth || 280))
    const cssH = this.estimateMobileLegendHeight()

    const prevLeft = this.legendLeft
    const prevLegendW = this.rightLegendW
    const prevContainerH = this.containerH

    this.legendLeft = 0
    this.rightLegendW = cssW
    this.containerH = cssH

    canvas.style.width = `${cssW}px`
    canvas.style.height = `${cssH}px`
    canvas.width = Math.max(1, Math.round(cssW * this.dpr))
    canvas.height = Math.max(1, Math.round(cssH * this.dpr))

    const ctx = canvas.getContext("2d")
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    ctx.clearRect(0, 0, cssW, cssH)
    ctx.lineWidth = 1

    this.drawLegend(ctx)
    this.drawTrackLegends(ctx)

    this._mobileLegendHit = {
      legendBounds: this.legendBounds,
      trackLegendBounds: Array.isArray(this.trackLegendBounds) ? [...this.trackLegendBounds] : []
    }
    this.legendBounds = null
    this.trackLegendBounds = []

    this.legendLeft = prevLeft
    this.rightLegendW = prevLegendW
    this.containerH = prevContainerH
  }

  onWheel(e) {
    // Plain scroll keeps page scrolling; Shift+scroll zooms the heatmap.
    if (!e.shiftKey) return
    const p = this.localPoint(e)
    if (!this.inMatrix(p)) return
    e.preventDefault()
    const factor = e.deltaY < 0 ? 0.85 : 1.176
    this.zoomAtPoint(p.x, p.y, factor)
  }

  zoomIn(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    this.zoomByFactor(0.85)
  }

  zoomOut(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    this.zoomByFactor(1.176)
  }

  zoomByFactor(factor) {
    if (!(this.mw > 0) || !(this.mh > 0)) return false
    return this.zoomAtPoint(this.mx + this.mw / 2, this.my + this.mh / 2, factor)
  }

  zoomAtPoint(x, y, factor) {
    if (!this.view || !(this.nDispCols > 0) || !(this.nDispRows > 0)) return false
    if (!(Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(factor) && factor > 0)) return false

    const v = this.view
    const cx = this.colForX(x)
    const cy = this.rowForY(y)
    if (!(Number.isFinite(cx) && Number.isFinite(cy))) return false

    let colSpan = (v.colEnd - v.colStart) * factor
    let rowSpan = (v.rowEnd - v.rowStart) * factor
    colSpan = Math.min(this.nDispCols, Math.max(1, colSpan))
    rowSpan = Math.min(this.nDispRows, Math.max(1, rowSpan))

    const colRange = v.colEnd - v.colStart
    const rowRange = v.rowEnd - v.rowStart
    if (!(colRange > 0) || !(rowRange > 0)) return false

    const colFrac = (cx - v.colStart) / colRange
    const rowFrac = (cy - v.rowStart) / rowRange

    v.colStart = cx - colFrac * colSpan
    v.colEnd = v.colStart + colSpan
    v.rowStart = cy - rowFrac * rowSpan
    v.rowEnd = v.rowStart + rowSpan
    this.clampView()
    this.render()
    return true
  }

  onPointerDown(e) {
    if (e.pointerType === "mouse" && e.button !== 0) return

    const p = this.localPoint(e)
    if (!this.inMatrix(p)) return

    e.preventDefault()
    try {
      this.overlayTarget.setPointerCapture?.(e.pointerId)
    } catch (_err) {
      // Some browsers reject capture if the pointer is already released.
    }
    this._activePointerId = e.pointerId

    // Touch devices rarely emit dblclick after preventDefault; synthesize double-tap clear.
    if (e.pointerType === "touch" || e.pointerType === "pen") {
      const now = performance.now()
      const last = this._lastHeatmapTap
      if (
        last &&
        now - last.t < 350 &&
        Math.hypot(p.x - last.x, p.y - last.y) < 28
      ) {
        this._lastHeatmapTap = null
        this.selecting = false
        this.selectionRect = null
        this.dragging = false
        this.dragStart = null
        this.clearLiveSelection()
        return
      }
      this._lastHeatmapTap = { t: now, x: p.x, y: p.y }
    }

    if (this.interactionMode === "select") {
      this.selecting = true
      this.selectionRect = { x0: p.x, y0: p.y, x1: p.x, y1: p.y }
      this.hideTooltip()
      this.drawOverlay()
      return
    }
    this.dragging = true
    this.dragStart = { x: p.x, y: p.y, view: { ...this.view } }
  }

  onPointerMove(e) {
    if (this._activePointerId != null && e.pointerId !== this._activePointerId) return

    const p = this.localPoint(e)

    if (this.selecting && this.selectionRect) {
      this.selectionRect.x1 = Math.max(this.mx, Math.min(this.mx + this.mw, p.x))
      this.selectionRect.y1 = Math.max(this.my, Math.min(this.my + this.mh, p.y))
      this.drawOverlay()
      return
    }

    if (this.dragging && this.dragStart) {
      const v0 = this.dragStart.view
      const colSpan = v0.colEnd - v0.colStart
      const rowSpan = v0.rowEnd - v0.rowStart
      const dCol = ((p.x - this.dragStart.x) / this.mw) * colSpan
      const dRow = ((p.y - this.dragStart.y) / this.mh) * rowSpan
      this.view.colStart = v0.colStart - dCol
      this.view.colEnd = v0.colEnd - dCol
      this.view.rowStart = v0.rowStart - dRow
      this.view.rowEnd = v0.rowEnd - dRow
      this.clampView()
      this.render()
      return
    }

    // Hover tooling is mouse-only; skip expensive hit-tests during unrelated touch moves.
    if (e.pointerType && e.pointerType !== "mouse") return

    const hoveringTarget = this.hitTestEditableLegend(p)
    const hoveringLegend = !!hoveringTarget
    const hoverKey = hoveringTarget?.type === "track"
      ? `${hoveringTarget.axis}:${hoveringTarget.track.id}`
      : (hoveringTarget ? "expression" : null)
    if (hoveringLegend !== this.isHoveringLegend || hoverKey !== this.hoveringTrackLegendKey) {
      this.isHoveringLegend = hoveringLegend
      this.hoveringTrackLegendKey = hoverKey
      if (this.interactionMode === "select") {
        this.overlayTarget.style.cursor = "crosshair"
      } else if (hoveringLegend) {
        this.overlayTarget.style.cursor = "pointer"
      } else {
        this.overlayTarget.style.cursor = "grab"
      }
      this.drawOverlay()
    }
    if (hoveringLegend) {
      this.hideTooltip()
      return
    }

    const trackHit = this.hitTestTracks(p)
    if (trackHit) {
      this.updateTrackTooltip(p, trackHit)
      return
    }
    if (this.inMatrix(p)) {
      this.updateTooltip(p, e)
    } else {
      this.hideTooltip()
    }
  }

  onPointerUp(e) {
    if (this._activePointerId != null && e.pointerId !== this._activePointerId) return
    this._activePointerId = null

    if (this.selecting && this.selectionRect) {
      this.commitSelectionRect(this.selectionRect)
      this.selecting = false
      this.selectionRect = null
      this.drawOverlay()
      return
    }
    this.dragging = false
    this.dragStart = null
  }

  // Keep legacy names for any residual call sites.
  onMouseDown(e) { this.onPointerDown(e) }
  onMouseMove(e) { this.onPointerMove(e) }
  onMouseUp(e) { this.onPointerUp(e || { pointerId: this._activePointerId }) }

  onDblClick(e) {
    const p = this.localPoint(e)
    if (!this.inMatrix(p)) return
    e.preventDefault()
    this.clearLiveSelection()
  }

  displayRangeFromRect(rect) {
    const x0 = Math.max(this.mx, Math.min(rect.x0, rect.x1))
    const x1 = Math.min(this.mx + this.mw, Math.max(rect.x0, rect.x1))
    const y0 = Math.max(this.my, Math.min(rect.y0, rect.y1))
    const y1 = Math.min(this.my + this.mh, Math.max(rect.y0, rect.y1))
    if (x1 <= x0 || y1 <= y0) return null

    let colStart = Math.floor(this.colForX(x0))
    let colEnd = Math.ceil(this.colForX(x1)) - 1
    let rowStart = Math.floor(this.rowForY(y0))
    let rowEnd = Math.ceil(this.rowForY(y1)) - 1

    colStart = Math.max(0, Math.min(this.nDispCols - 1, colStart))
    colEnd = Math.max(0, Math.min(this.nDispCols - 1, colEnd))
    rowStart = Math.max(0, Math.min(this.nDispRows - 1, rowStart))
    rowEnd = Math.max(0, Math.min(this.nDispRows - 1, rowEnd))
    if (colEnd < colStart) colEnd = colStart
    if (rowEnd < rowStart) rowEnd = rowStart
    return { colStart, colEnd, rowStart, rowEnd }
  }

  commitSelectionRect(rect) {
    const range = this.displayRangeFromRect(rect)
    if (!range) return

    const rowLabels = this.meta?.row_labels || []
    const colLabels = this.meta?.col_labels || []
    const colCellIndices = this.meta?.col_cell_indices
    const columnMode = String(this.meta?.column_mode || "cells")
    const newlySelectedSymbols = []

    for (let d = range.rowStart; d <= range.rowEnd; d++) {
      const group = this.rowGroups[d]
      if (!group) continue
      for (let i = group[0]; i <= group[1]; i++) {
        const label = rowLabels[i]
        if (label != null && String(label).trim() !== "") {
          newlySelectedSymbols.push(String(label))
        }
      }
    }

    this.beginGeneListHistoryBatch()
    try {
      for (const symbol of newlySelectedSymbols) {
        this.addGeneToList(symbol, { checked: true, render: false, sync: false })
      }
      if (newlySelectedSymbols.length) {
        this.applyGeneListHighlightState()
        this.renderGeneSearchList()
      }
    } finally {
      this.endGeneListHistoryBatch()
    }

    for (let d = range.colStart; d <= range.colEnd; d++) {
      const group = this.colGroups[d]
      if (!group) continue
      for (let i = group[0]; i <= group[1]; i++) {
        this.selectedOrigCols.add(i)
        const indices = Array.isArray(colCellIndices) ? colCellIndices[i] : null
        if (Array.isArray(indices) && indices.length) {
          for (const idx of indices) {
            const n = Number(idx)
            if (Number.isInteger(n) && n >= 0) this.selectedCells.add(n)
          }
          continue
        }
        if (columnMode === "group") continue
        const label = colLabels[i]
        if (label == null || String(label).trim() === "") continue
        const asInt = Number(label)
        if (Number.isInteger(asInt) && String(asInt) === String(label).trim()) {
          this.selectedCells.add(asInt)
        }
      }
    }

    this.updateSelectionPanels()
    this.refreshExpandedGeneHistograms()
    this.persistCurrentCheckpointOnServer("selection-change")
  }

  clearLiveSelection(event) {
    if (event) event.preventDefault()
    this.beginGeneListHistoryBatch()
    try {
      this.selectedGenes.clear()
      this.selectedCells.clear()
      this.selectedOrigRows.clear()
      this.selectedOrigCols.clear()
      this.geneListItems = []
      this.selectionRect = null
      this.selecting = false
      this.renderGeneSearchList()
      this.updateSelectionPanels()
      this.drawOverlay()
      this.persistCurrentCheckpointOnServer("selection-change")
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  clearGeneSelection(event) {
    if (event) event.preventDefault()
    this.beginGeneListHistoryBatch()
    try {
      this.selectedGenes.clear()
      this.selectedOrigRows.clear()
      this.geneListItems = []
      this.renderGeneSearchList()
      this.updateSelectionPanels()
      this.drawOverlay()
      this.persistCurrentCheckpointOnServer("selection-change")
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  clearCellSelection(event) {
    if (event) event.preventDefault()
    this.selectedCells.clear()
    this.selectedOrigCols.clear()
    this.updateSelectionPanels()
    this.refreshExpandedGeneHistograms()
    this.drawOverlay()
    this.persistCurrentCheckpointOnServer("selection-change")
  }

  updateSelectionPanels() {
    const highlightedCount = this.geneListItems.filter((item) => item.checked).length
    if (this.hasSelectedGenesCountTarget) {
      this.selectedGenesCountTarget.textContent = String(highlightedCount)
    }
    if (this.hasSelectedCellsCountTarget) {
      this.selectedCellsCountTarget.textContent = String(this.selectedCells.size)
    }
    if (this.hasClearGeneSelectionBtnTarget) {
      this.clearGeneSelectionBtnTarget.style.display = this.geneListItems.length > 0 ? "inline-flex" : "none"
    }
    this.updateGeneListHistoryControls()
    if (this.hasGeneSetOverlapBtnTarget) {
      this.geneSetOverlapBtnTarget.style.display = highlightedCount > 0 ? "inline-flex" : "none"
    }
    if (this.hasClearCellSelectionBtnTarget) {
      this.clearCellSelectionBtnTarget.style.display = this.selectedCells.size > 0 ? "inline-flex" : "none"
    }
    this.syncToggleAllGenesButton()
  }

  syncToggleAllGenesButton() {
    if (!this.hasToggleAllGenesBtnTarget) return
    const total = this.geneListItems.length
    if (total <= 0) {
      this.toggleAllGenesBtnTarget.style.display = "none"
      return
    }
    const allChecked = this.geneListItems.every((item) => item.checked)
    this.toggleAllGenesBtnTarget.style.display = "inline-flex"
    this.toggleAllGenesBtnTarget.textContent = allChecked ? "Unselect all" : "Select all"
    this.toggleAllGenesBtnTarget.title = allChecked
      ? "Unselect all genes in the list"
      : "Select all genes in the list"
    this.toggleAllGenesBtnTarget.setAttribute(
      "aria-label",
      allChecked ? "Unselect all genes in the list" : "Select all genes in the list"
    )
  }

  toggleAllGeneSelection(event) {
    if (event) event.preventDefault()
    if (!this.geneListItems.length) return
    const allChecked = this.geneListItems.every((item) => item.checked)
    const nextChecked = !allChecked
    for (const item of this.geneListItems) {
      item.checked = nextChecked
    }
    this.applyGeneListHighlightState()
    this.renderGeneSearchList()
    this.persistCurrentCheckpointOnServer("selection-change")
  }

  openGeneSetOverlapPopup(event) {
    if (event) event.preventDefault()
    if (!this.geneSetOverlapPopup) return
    this.geneSetOverlapPopup.open()
  }

  switchSelectionTab(event) {
    if (event) event.preventDefault()
    const tab = event?.currentTarget?.dataset?.tab
    this.setSelectionTab(tab)
    this.persistCurrentCheckpointOnServer("selection-tab-change")
  }

  // Used by GeneSetCollectionsController after creating/saving collections.
  setSelectionTab(tab = "cells") {
    const normalizedTab = tab === "gene-sets" ? "gene-sets" : "cells"
    const cellsTab = this.element.querySelector("#heatmap-cells-tab")
    const geneSetsTab = this.element.querySelector("#heatmap-gene-sets-tab")
    const cellsContent = this.element.querySelector("#heatmap-cells-tab-content")
    const geneSetsContent = this.element.querySelector("#heatmap-gene-sets-tab-content")
    if (!cellsTab || !geneSetsTab || !cellsContent || !geneSetsContent) return

    this.currentSelectionTab = normalizedTab

    const activate = (button, content, active) => {
      button.style.color = active ? "#3b82f6" : "#6b7280"
      button.style.borderBottomColor = active ? "#3b82f6" : "transparent"
      content.style.display = active ? "flex" : "none"
    }

    activate(cellsTab, cellsContent, normalizedTab === "cells")
    activate(geneSetsTab, geneSetsContent, normalizedTab === "gene-sets")
  }

  async replaceGenesFromGeneSet(geneEntries) {
    this.beginGeneListHistoryBatch()
    try {
      const entries = Array.isArray(geneEntries) ? geneEntries : []
      this.geneListItems = []
      for (const entry of entries) {
        const candidates = [
          entry?.symbol,
          entry?.name,
          entry?.ensembl_id,
          entry?.ensemblId
        ]
        for (const candidate of candidates) {
          const query = String(candidate || "").trim()
          if (!query) continue
          if (this.addGeneToList(query, { checked: true, render: false, sync: false })) break
        }
      }
      this.applyGeneListHighlightState()
      this.renderGeneSearchList()
      this.persistCurrentCheckpointOnServer("selection-change")
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  snapshotGeneList() {
    return (Array.isArray(this.geneListItems) ? this.geneListItems : []).map((item) => ({ ...item }))
  }

  geneListHistoryKey(items) {
    return (Array.isArray(items) ? items : [])
      .map((item) => String(item?.symbol || "").trim().toLowerCase())
      .filter((symbol) => symbol.length > 0)
      .join("|")
  }

  geneListHistoryLabel(items) {
    const list = Array.isArray(items) ? items : []
    if (list.length === 0) return "Empty gene list"
    const symbols = list
      .map((item) => String(item?.symbol || "").trim())
      .filter((symbol) => symbol.length > 0)
    const preview = symbols.slice(0, 3).join(", ")
    const suffix = symbols.length > 3 ? ", ..." : ""
    return `${list.length} gene${list.length === 1 ? "" : "s"}: ${preview}${suffix}`
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
    const afterKey = this.geneListHistoryKey(this.geneListItems)
    if (beforeKey === afterKey) {
      this.updateGeneListHistoryControls()
      return
    }
    this.pushGeneListHistoryEntry(before)
    this.updateGeneListHistoryControls()
  }

  pushGeneListHistoryEntry(snapshot) {
    if (!Array.isArray(this.geneListHistory)) this.geneListHistory = []
    const genes = Array.isArray(snapshot) ? snapshot.map((item) => ({ ...item })) : []
    this.geneListHistory.unshift({
      genes,
      label: this.geneListHistoryLabel(genes)
    })
    if (this.geneListHistory.length > 10) {
      this.geneListHistory = this.geneListHistory.slice(0, 10)
    }
  }

  updateGeneListHistoryControls() {
    const historyCount = Array.isArray(this.geneListHistory) ? this.geneListHistory.length : 0
    const showControls = historyCount > 0

    if (this.hasRestorePreviousGenesBtnTarget) {
      this.restorePreviousGenesBtnTarget.style.display = showControls ? "inline-flex" : "none"
      this.restorePreviousGenesBtnTarget.disabled = !showControls
    }
    if (this.hasGeneListHistoryBtnTarget) {
      this.geneListHistoryBtnTarget.style.display = showControls ? "inline-flex" : "none"
      this.geneListHistoryBtnTarget.disabled = !showControls
      this.geneListHistoryBtnTarget.title = showControls
        ? `Gene list history (${historyCount})`
        : "Gene list history"
    }
    if (!showControls) this.closeGeneListHistoryMenu()
  }

  closeGeneListHistoryMenu() {
    if (this.hasGeneListHistoryMenuTarget) {
      this.geneListHistoryMenuTarget.style.display = "none"
    }
  }

  preventGeneListHistoryMenuClose(event) {
    if (event) event.stopPropagation()
  }

  toggleGeneListHistoryMenu(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (!this.hasGeneListHistoryMenuTarget) return
    const isOpen = this.geneListHistoryMenuTarget.style.display === "block"
    this.closeGeneListHistoryMenu()
    if (isOpen) return
    this.renderGeneListHistoryMenu()
    this.geneListHistoryMenuTarget.style.display = "block"
  }

  renderGeneListHistoryMenu() {
    if (!this.hasGeneListHistoryMenuTarget) return
    const menu = this.geneListHistoryMenuTarget
    menu.innerHTML = ""
    const entries = Array.isArray(this.geneListHistory) ? this.geneListHistory : []
    if (entries.length === 0) {
      const empty = document.createElement("div")
      empty.style.cssText = "padding:10px 12px;font-size:12px;color:#6b7280;"
      empty.textContent = "No previous gene lists"
      menu.appendChild(empty)
      return
    }

    entries.forEach((entry, index) => {
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.historyIndex = String(index)
      button.style.cssText = "display:block;width:100%;text-align:left;padding:8px 12px;border:none;background:none;cursor:pointer;font-size:12px;color:#374151;border-bottom:1px solid #f3f4f6;"
      const label = entry.label || this.geneListHistoryLabel(entry.genes)
      button.textContent = label
      button.title = label
      button.addEventListener("mouseenter", () => { button.style.backgroundColor = "#f3f4f6" })
      button.addEventListener("mouseleave", () => { button.style.backgroundColor = "" })
      button.addEventListener("click", (clickEvent) => this.applyGeneListHistoryEntry(clickEvent))
      menu.appendChild(button)
    })
  }

  restorePreviousGenes(event) {
    if (event) event.preventDefault()
    this.closeGeneListHistoryMenu()
    if (!Array.isArray(this.geneListHistory) || this.geneListHistory.length === 0) return
    const previous = this.geneListHistory.shift()
    this.updateGeneListHistoryControls()
    this.applyGeneListSnapshot(previous?.genes || [])
  }

  applyGeneListHistoryEntry(event) {
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
    this.applyGeneListSnapshot(entry?.genes || [])
  }

  applyGeneListSnapshot(items) {
    this.beginGeneListHistoryBatch()
    try {
      this.geneListItems = (Array.isArray(items) ? items : []).map((item) => ({
        symbol: item.symbol,
        checked: item.checked !== false,
        expanded: !!item.expanded
      }))
      this.applyGeneListHighlightState()
      this.renderGeneSearchList()
      this.persistCurrentCheckpointOnServer("selection-change")
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  rebuildGeneRowIndex() {
    this.geneRowIndexBySymbol = new Map()
    const rowLabels = this.meta?.row_labels || []
    for (let i = 0; i < rowLabels.length; i++) {
      const label = rowLabels[i]
      if (label == null) continue
      const symbol = String(label).trim()
      if (!symbol) continue
      const key = symbol.toLowerCase()
      let entry = this.geneRowIndexBySymbol.get(key)
      if (!entry) {
        entry = { symbol, indices: [] }
        this.geneRowIndexBySymbol.set(key, entry)
      }
      entry.indices.push(i)
    }
  }

  resolveGeneSymbol(query) {
    const raw = String(query || "").trim()
    if (!raw) return null
    const entry = this.geneRowIndexBySymbol.get(raw.toLowerCase())
    return entry ? entry.symbol : null
  }

  rowIndicesForSymbol(symbol) {
    const entry = this.geneRowIndexBySymbol.get(String(symbol || "").toLowerCase())
    return entry ? entry.indices.slice() : []
  }

  addGeneToList(symbol, { checked = true, render = true, sync = true } = {}) {
    const resolved = this.resolveGeneSymbol(symbol)
    if (!resolved) return null
    const existing = this.geneListItems.find((item) => item.symbol.toLowerCase() === resolved.toLowerCase())
    if (existing) {
      if (checked && !existing.checked) {
        existing.checked = true
        if (sync) this.applyGeneListHighlightState()
        if (render) this.renderGeneSearchList()
      }
      return existing
    }
    this.beginGeneListHistoryBatch()
    try {
      const item = { symbol: resolved, checked: !!checked, expanded: false }
      this.geneListItems.push(item)
      if (sync && checked) this.applyGeneListHighlightState()
      if (render) this.renderGeneSearchList()
      return item
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  applyGeneListHighlightState() {
    this.selectedGenes.clear()
    this.selectedOrigRows.clear()
    for (const item of this.geneListItems) {
      if (!item.checked) continue
      this.selectedGenes.add(item.symbol)
      for (const rowIndex of this.rowIndicesForSymbol(item.symbol)) {
        this.selectedOrigRows.add(rowIndex)
      }
    }
    this.updateSelectionPanels()
    if (typeof this.drawOverlay === "function") this.drawOverlay()
  }

  renderGeneSearchList() {
    if (!this.hasGeneSearchListTarget) return
    const listEl = this.geneSearchListTarget
    const emptyEl = this.hasGeneSearchListEmptyTarget ? this.geneSearchListEmptyTarget : null

    listEl.querySelectorAll("[data-heatmap-gene-item='true']").forEach((node) => node.remove())

    if (!this.geneListItems.length) {
      if (emptyEl) emptyEl.style.display = "block"
      this.updateSelectionPanels()
      return
    }
    if (emptyEl) emptyEl.style.display = "none"

    for (const item of this.geneListItems) {
      listEl.appendChild(this.buildGeneListItemElement(item))
    }
    this.updateSelectionPanels()
    requestAnimationFrame(() => this.refreshExpandedGeneHistograms())
  }

  buildGeneListItemElement(item) {
    const symbol = item.symbol
    const safeSymbol = this.escapeHtml(symbol)
    const expanded = !!item.expanded
    const checked = !!item.checked
    const card = document.createElement("div")
    card.dataset.heatmapGeneItem = "true"
    card.dataset.geneSymbol = symbol
    card.style.cssText = "flex:0 0 auto;background:#fff;border:1px solid #e5e7eb;border-radius:6px;overflow:hidden;"

    const header = document.createElement("div")
    header.className = "heatmap-gene-header"
    header.dataset.action = "click->heatmap#onGeneListHeaderClick"
    header.dataset.geneSymbol = symbol
    header.style.cssText = "display:flex;align-items:center;gap:8px;padding:8px 10px;min-height:36px;box-sizing:border-box;cursor:pointer;user-select:none;"
    header.onmouseover = function () { this.style.backgroundColor = "#f9fafb" }
    header.onmouseout = function () { this.style.backgroundColor = "" }
    header.innerHTML = `
      <div class="heatmap-gene-chevron" style="color:#9ca3af;display:flex;align-items:center;justify-content:center;width:14px;flex:0 0 auto;">
        <i class="fas fa-chevron-right" style="font-size:12px;transition:transform 0.2s ease-out;transform:${expanded ? "rotate(90deg)" : "none"};"></i>
      </div>
      <input type="checkbox"
             ${checked ? "checked" : ""}
             data-action="click->heatmap#onGeneListCheckboxClick change->heatmap#onGeneListCheckboxChange"
             data-gene-symbol="${safeSymbol}"
             aria-label="Highlight ${safeSymbol}"
             style="margin:0;flex:0 0 auto;cursor:pointer;" />
      <div class="heatmap-gene-symbol"
           style="flex:1;min-width:0;font-size:13px;font-weight:500;color:#111827;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;"
           title="${safeSymbol}">
        ${safeSymbol}
      </div>
      <button type="button"
              class="heatmap-gene-info-btn"
              data-action="click->heatmap#onGeneListInfoClick"
              data-gene-symbol="${safeSymbol}"
              title="More gene information"
              aria-label="More information about ${safeSymbol}"
              style="padding:4px;color:#9ca3af;background:none;border:none;border-radius:4px;cursor:pointer;flex:0 0 auto;"
              onmouseover="this.style.color='#6b7280';this.style.backgroundColor='#f3f4f6';"
              onmouseout="this.style.color='#9ca3af';this.style.backgroundColor='';">
        <i class="fas fa-info-circle" style="font-size:14px;"></i>
      </button>
      <button type="button"
              data-action="click->heatmap#onGeneListRemove"
              data-gene-symbol="${safeSymbol}"
              title="Remove ${safeSymbol}"
              aria-label="Remove ${safeSymbol}"
              style="background:none;border:none;color:#6b7280;cursor:pointer;padding:4px;font-size:16px;line-height:1;width:22px;height:22px;display:flex;align-items:center;justify-content:center;border-radius:4px;flex:0 0 auto;"
              onmouseover="this.style.backgroundColor='#fee2e2';this.style.color='#dc2626';"
              onmouseout="this.style.backgroundColor='';this.style.color='#6b7280';">
        x
      </button>
    `

    const body = document.createElement("div")
    body.className = "heatmap-gene-range-section"
    body.dataset.geneSymbol = symbol
    body.style.cssText = `padding:10px 12px;border-top:1px solid #f3f4f6;background:#fafafa;display:${expanded ? "block" : "none"};`
    body.innerHTML = `
      <div class="heatmap-gene-hist-caption" style="font-size:11px;color:#6b7280;margin-bottom:6px;line-height:1.35;">
        Expression over selected cells
      </div>
      <canvas class="heatmap-gene-hist-canvas"
              data-gene-symbol="${safeSymbol}"
              style="width:100%;height:90px;border:1px solid #e5e7eb;border-radius:4px;background:#fff;display:block;"></canvas>
      <div class="heatmap-gene-hist-status" style="margin-top:6px;font-size:11px;color:#9ca3af;"></div>
    `

    card.appendChild(header)
    card.appendChild(body)
    return card
  }

  onGeneListHeaderClick(event) {
    if (event.target.closest("button") || event.target.closest("input")) return
    const symbol = event?.currentTarget?.dataset?.geneSymbol
    if (!symbol) return
    const item = this.geneListItems.find((entry) => entry.symbol === symbol)
    if (!item) return
    item.expanded = !item.expanded
    this.renderGeneSearchList()
  }

  onGeneListCheckboxClick(event) {
    event.stopPropagation()
  }

  onGeneListCheckboxChange(event) {
    const symbol = event?.currentTarget?.dataset?.geneSymbol
    if (!symbol) return
    const item = this.geneListItems.find((entry) => entry.symbol === symbol)
    if (!item) return
    item.checked = !!event.currentTarget.checked
    this.applyGeneListHighlightState()
    this.persistCurrentCheckpointOnServer("selection-change")
  }

  onGeneListInfoClick(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const symbol = event?.currentTarget?.dataset?.geneSymbol
    if (!symbol) return
    const searchUrl = this.searchGeneUrlValue || document.getElementById("annotation-popup-overlay")?.dataset?.searchGeneUrl || ""
    if (!window.openAnnotationPopupGeneModal || !searchUrl) {
      alert("Gene details are not available on this page.")
      return
    }
    window.openAnnotationPopupGeneModal("", searchUrl, symbol, "", {
      loomFile: this.loomFile || ""
    })
  }

  onGeneListRemove(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const symbol = event?.currentTarget?.dataset?.geneSymbol
    if (!symbol) return
    this.beginGeneListHistoryBatch()
    try {
      this.geneListItems = this.geneListItems.filter((entry) => entry.symbol !== symbol)
      this.applyGeneListHighlightState()
      this.renderGeneSearchList()
      this.persistCurrentCheckpointOnServer("selection-change")
    } finally {
      this.endGeneListHistoryBatch()
    }
  }

  expressionValuesForGene(symbol) {
    if (!this.baseMatrix || !this.nOrigCols) return { values: [], columnCount: 0, usedSelection: false }
    const rowIndices = this.rowIndicesForSymbol(symbol)
    if (!rowIndices.length) return { values: [], columnCount: 0, usedSelection: false }

    const selectedCols = this.selectedOrigCols && this.selectedOrigCols.size
      ? Array.from(this.selectedOrigCols).filter((c) => Number.isInteger(c) && c >= 0 && c < this.nOrigCols)
      : null
    const cols = selectedCols && selectedCols.length
      ? selectedCols
      : Array.from({ length: this.nOrigCols }, (_, i) => i)
    const values = []
    for (const rowIndex of rowIndices) {
      const rowOff = rowIndex * this.nOrigCols
      for (const col of cols) {
        const v = this.baseMatrix[rowOff + col]
        if (typeof v === "number" && Number.isFinite(v)) values.push(v)
      }
    }
    return {
      values,
      columnCount: cols.length,
      usedSelection: !!(selectedCols && selectedCols.length)
    }
  }

  refreshExpandedGeneHistograms() {
    if (!this.hasGeneSearchListTarget) return
    const cards = Array.from(this.geneSearchListTarget.querySelectorAll("[data-heatmap-gene-item='true']"))
    for (const item of this.geneListItems) {
      if (!item.expanded) continue
      const card = cards.find((el) => el.dataset.geneSymbol === item.symbol)
      if (!card) continue
      this.drawGeneListHistogram(card, item.symbol)
    }
  }

  drawGeneListHistogram(card, symbol) {
    const canvas = card.querySelector(".heatmap-gene-hist-canvas")
    const caption = card.querySelector(".heatmap-gene-hist-caption")
    const status = card.querySelector(".heatmap-gene-hist-status")
    if (!canvas) return

    const showCompactMessage = (message) => {
      if (caption) {
        caption.style.display = "none"
        caption.textContent = ""
      }
      canvas.style.display = "none"
      if (status) {
        status.style.display = "block"
        status.style.marginTop = "0"
        status.textContent = message
      }
    }

    const showHistogramChrome = () => {
      if (caption) caption.style.display = "block"
      canvas.style.display = "block"
      if (status) status.style.marginTop = "6px"
    }

    const { values, columnCount, usedSelection } = this.expressionValuesForGene(symbol)

    if (!values.length) {
      showCompactMessage("No expression values available for this gene.")
      return
    }

    const minEdge = this.safeMin(values)
    const maxEdge = this.safeMax(values)
    if (!(maxEdge > minEdge) || !Number.isFinite(minEdge) || !Number.isFinite(maxEdge)) {
      if (Number.isFinite(minEdge) && minEdge === 0) {
        showCompactMessage("All values are 0.")
        return
      }
      showCompactMessage(
        Number.isFinite(minEdge)
          ? `All values are ${minEdge.toFixed(3)}.`
          : "No finite expression values."
      )
      return
    }

    showHistogramChrome()
    if (caption) {
      caption.textContent = usedSelection
        ? `Expression over ${columnCount} selected heatmap column${columnCount === 1 ? "" : "s"}`
        : `Expression over all ${columnCount} heatmap column${columnCount === 1 ? "" : "s"} (no cell selection)`
    }

    const ctx = canvas.getContext("2d")
    if (!ctx) return
    const dpr = window.devicePixelRatio || 1
    const rect = canvas.getBoundingClientRect()
    const width = Math.max(1, Math.floor(rect.width || canvas.clientWidth || 240))
    const height = Math.max(1, Math.floor(rect.height || 90))
    canvas.width = width * dpr
    canvas.height = height * dpr
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, width, height)
    ctx.fillStyle = "#ffffff"
    ctx.fillRect(0, 0, width, height)

    const numBins = 40
    const padL = 8
    const padR = 8
    const padT = 8
    const padB = 22
    const plotW = Math.max(1, width - padL - padR)
    const plotH = Math.max(1, height - padT - padB)
    const { bins, maxCount } = this.buildHistogramBins(values, minEdge, maxEdge, numBins, {
      scale: "normal",
      ignoreZeros: false
    })
    const denom = maxCount > 0 ? maxCount : 1
    const barWidth = plotW / numBins

    ctx.fillStyle = "#9ca3af"
    for (let i = 0; i < numBins; i++) {
      const count = bins[i] || 0
      const barH = (count / denom) * plotH
      const x = padL + i * barWidth
      const y = padT + plotH - barH
      ctx.fillRect(x, y, Math.max(1, barWidth - 1), barH)
    }

    ctx.fillStyle = "#6b7280"
    ctx.font = "10px sans-serif"
    ctx.textBaseline = "top"
    ctx.textAlign = "left"
    ctx.fillText(minEdge.toFixed(2), padL, height - padB + 4)
    ctx.textAlign = "right"
    ctx.fillText(maxEdge.toFixed(2), width - padR, height - padB + 4)

    if (status) {
      status.textContent = `${values.length} value${values.length === 1 ? "" : "s"} · min ${minEdge.toFixed(3)} · max ${maxEdge.toFixed(3)}`
    }
  }

  onGeneSearchInput(event) {
    const query = String(event?.currentTarget?.value || "").trim()
    if (!query) {
      this.hideGeneSearchDropdown()
      return
    }
    this.geneSearchMatches = this.findGeneSearchMatches(query, 30)
    this.geneSearchActiveIndex = this.geneSearchMatches.length ? 0 : -1
    this.renderGeneSearchDropdown()
  }

  onGeneSearchKeydown(event) {
    const key = event?.key
    if (key === "Escape") {
      this.hideGeneSearchDropdown()
      return
    }
    if (key === "ArrowDown") {
      if (!this.geneSearchMatches.length) return
      event.preventDefault()
      this.geneSearchActiveIndex = Math.min(this.geneSearchMatches.length - 1, this.geneSearchActiveIndex + 1)
      this.renderGeneSearchDropdown()
      return
    }
    if (key === "ArrowUp") {
      if (!this.geneSearchMatches.length) return
      event.preventDefault()
      this.geneSearchActiveIndex = Math.max(0, this.geneSearchActiveIndex - 1)
      this.renderGeneSearchDropdown()
      return
    }
    if (key === "Enter") {
      event.preventDefault()
      if (this.geneSearchMatches.length && this.geneSearchActiveIndex >= 0) {
        this.selectGeneSearchMatch(this.geneSearchMatches[this.geneSearchActiveIndex])
        return
      }
      const typed = String(this.hasGeneSearchInputTarget ? this.geneSearchInputTarget.value : "").trim()
      if (!typed) return
      const resolved = this.resolveGeneSymbol(typed)
      if (!resolved) {
        if (this.hasGeneSelectionStatusTarget) {
          this.geneSelectionStatusTarget.textContent = `Gene "${typed}" is not in this heatmap.`
        }
        return
      }
      this.selectGeneSearchMatch(resolved)
    }
  }

  onGeneSearchBlur() {
    if (this.geneSearchBlurTimer) clearTimeout(this.geneSearchBlurTimer)
    this.geneSearchBlurTimer = setTimeout(() => this.hideGeneSearchDropdown(), 150)
  }

  findGeneSearchMatches(query, limit = 30) {
    const q = String(query || "").trim().toLowerCase()
    if (!q || !this.geneRowIndexBySymbol.size) return []
    const prefix = []
    const contains = []
    for (const entry of this.geneRowIndexBySymbol.values()) {
      const symbol = entry.symbol
      const key = symbol.toLowerCase()
      if (key.startsWith(q)) prefix.push(symbol)
      else if (key.includes(q)) contains.push(symbol)
    }
    prefix.sort((a, b) => a.localeCompare(b))
    contains.sort((a, b) => a.localeCompare(b))
    return prefix.concat(contains).slice(0, limit)
  }

  renderGeneSearchDropdown() {
    if (!this.hasGeneSearchDropdownTarget) return
    const dropdown = this.geneSearchDropdownTarget
    dropdown.innerHTML = ""
    if (!this.geneSearchMatches.length) {
      dropdown.style.display = "none"
      return
    }
    this.geneSearchMatches.forEach((symbol, index) => {
      const already = this.geneListItems.some((item) => item.symbol.toLowerCase() === symbol.toLowerCase())
      const option = document.createElement("button")
      option.type = "button"
      option.dataset.geneSymbol = symbol
      option.dataset.action = "mousedown->heatmap#onGeneSearchOptionSelect"
      option.dataset.heatmapSearchIndex = String(index)
      const active = index === this.geneSearchActiveIndex
      option.style.cssText = [
        "display:flex",
        "align-items:center",
        "justify-content:space-between",
        "width:100%",
        "padding:7px 10px",
        "border:none",
        "background:" + (active ? "#eff6ff" : "#fff"),
        "color:#111827",
        "font-size:12px",
        "text-align:left",
        "cursor:pointer"
      ].join(";")
      const nameSpan = document.createElement("span")
      nameSpan.textContent = symbol
      option.appendChild(nameSpan)
      if (already) {
        const badge = document.createElement("span")
        badge.textContent = "added"
        badge.style.cssText = "font-size:11px;color:#6b7280;"
        option.appendChild(badge)
      }
      option.addEventListener("mouseenter", () => {
        this.geneSearchActiveIndex = index
        dropdown.querySelectorAll("button[data-heatmap-search-index]").forEach((btn) => {
          const isActive = Number(btn.dataset.heatmapSearchIndex) === index
          btn.style.background = isActive ? "#eff6ff" : "#fff"
        })
      })
      dropdown.appendChild(option)
    })
    dropdown.style.display = "block"
  }

  hideGeneSearchDropdown() {
    this.geneSearchMatches = []
    this.geneSearchActiveIndex = -1
    if (this.hasGeneSearchDropdownTarget) {
      this.geneSearchDropdownTarget.style.display = "none"
      this.geneSearchDropdownTarget.innerHTML = ""
    }
  }

  onGeneSearchOptionSelect(event) {
    if (event) event.preventDefault()
    const symbol = event?.currentTarget?.dataset?.geneSymbol
    if (!symbol) return
    this.selectGeneSearchMatch(symbol)
  }

  selectGeneSearchMatch(symbol) {
    this.addGeneToList(symbol, { checked: true, render: true })
    if (this.hasGeneSearchInputTarget) this.geneSearchInputTarget.value = ""
    this.hideGeneSearchDropdown()
    if (this.hasGeneSelectionStatusTarget) this.geneSelectionStatusTarget.textContent = ""
    this.focusGeneInHeatmap(symbol)
    this.scrollGeneListToSymbol(symbol)
    this.persistCurrentCheckpointOnServer("selection-change")
  }

  focusGeneInHeatmap(symbol) {
    if (!this.view || !this.nDispRows || !this.origRowToDisplay) return
    const rowIndices = this.rowIndicesForSymbol(symbol)
    if (!rowIndices.length) return

    const displayRows = []
    for (const rowIndex of rowIndices) {
      const displayRow = this.origRowToDisplay[rowIndex]
      if (Number.isFinite(displayRow)) displayRows.push(displayRow)
    }
    if (!displayRows.length) return

    const target = (Math.min(...displayRows) + Math.max(...displayRows) + 1) / 2
    const rowSpan = Math.max(1, this.view.rowEnd - this.view.rowStart)
    this.view.rowStart = target - rowSpan / 2
    this.view.rowEnd = this.view.rowStart + rowSpan
    this.clampView()
    this.render()
  }

  scrollGeneListToSymbol(symbol) {
    if (!this.hasGeneSearchListTarget || !symbol) return
    const target = String(symbol)
    const scrollIntoView = () => {
      const cards = Array.from(this.geneSearchListTarget.querySelectorAll("[data-heatmap-gene-item='true']"))
      const card = cards.find((el) => el.dataset.geneSymbol === target)
      if (!card) return
      card.scrollIntoView({ block: "nearest", behavior: "smooth" })
    }
    requestAnimationFrame(scrollIntoView)
  }

  escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  clampView() {
    const v = this.view
    let colSpan = Math.min(this.nDispCols, v.colEnd - v.colStart)
    let rowSpan = Math.min(this.nDispRows, v.rowEnd - v.rowStart)
    if (v.colStart < 0) { v.colEnd = colSpan; v.colStart = 0 }
    if (v.colEnd > this.nDispCols) { v.colEnd = this.nDispCols; v.colStart = this.nDispCols - colSpan }
    if (v.rowStart < 0) { v.rowEnd = rowSpan; v.rowStart = 0 }
    if (v.rowEnd > this.nDispRows) { v.rowEnd = this.nDispRows; v.rowStart = this.nDispRows - rowSpan }
  }

  // Click on expression or continuous-track legend opens the shared gradient editor.
  onClick(e) {
    if (this.interactionMode === "select") return
    const p = this.localPoint(e)
    const legendHit = this.hitTestEditableLegend(p)
    if (legendHit) {
      if (legendHit.type === "expression") this.openExpressionGradientEditor()
      else this.openTrackGradientEditor(legendHit.track, legendHit.axis)
    }
  }

  inLegend(p) {
    return !!this.hitTestEditableLegend(p)
  }

  hitTestEditableLegend(p) {
    const b = this.legendBounds
    if (b && p.x >= b.x && p.x <= b.x + b.width && p.y >= b.y && p.y <= b.y + b.height) {
      return { type: "expression" }
    }
    for (const entry of (this.trackLegendBounds || [])) {
      const bb = entry.bounds
      if (p.x >= bb.x && p.x <= bb.x + bb.width && p.y >= bb.y && p.y <= bb.y + bb.height) {
        return { type: "track", track: entry.track, axis: entry.axis }
      }
    }
    return null
  }

  nodeDisplayCenter(node, axis) {
    const map = axis === "col" ? this.origColToDisplay : this.origRowToDisplay
    const ds = map[node.minLeaf]
    const de = map[node.maxLeaf]
    return (ds + de + 1) / 2
  }

  render() {
    if (!this.renderer) return
    this.renderer.render(this.view)
    this.drawOverlay()
  }

  drawOverlay() {
    const ctx = this.overlayTarget.getContext("2d")
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    ctx.clearRect(0, 0, this.containerW, this.containerH)
    ctx.lineWidth = 1

    // matrix border
    ctx.strokeStyle = "#cbd5e1"
    ctx.strokeRect(this.mx, this.my, this.mw, this.mh)

    this.drawSelectionHighlights(ctx)

    if (this.showColTree && this.colTree) this.drawDendrogram(ctx, this.colTree, "col")
    if (this.showRowTree && this.rowTree) this.drawDendrogram(ctx, this.rowTree, "row")

    this.drawTracks(ctx)
    if (this.showLabels) this.drawLabels(ctx)
    this.drawSelectedGeneZoomedOutMarks(ctx)
    if (this.isMobileHeatmapLayout()) {
      this.legendBounds = null
      this.trackLegendBounds = []
      if (this.element?.dataset?.mobilePanel === "legend") {
        this.drawMobileLegend()
      }
    } else {
      this.drawLegend(ctx)
      this.drawTrackLegends(ctx)
    }
    this.drawActiveSelectionRect(ctx)
  }

  drawSelectionHighlights(ctx) {
    if (!this.selectedOrigRows?.size && !this.selectedOrigCols?.size) return
    const v = this.view
    ctx.save()
    ctx.beginPath()
    ctx.rect(this.mx, this.my, this.mw, this.mh)
    ctx.clip()

    if (this.selectedOrigRows?.size && this.rowGroups) {
      ctx.fillStyle = "rgba(37, 99, 235, 0.10)"
      for (let d = 0; d < this.nDispRows; d++) {
        const group = this.rowGroups[d]
        if (!group) continue
        let hit = false
        for (let i = group[0]; i <= group[1]; i++) {
          if (this.selectedOrigRows.has(i)) { hit = true; break }
        }
        if (!hit) continue
        if (d + 1 <= v.rowStart || d >= v.rowEnd) continue
        const y0 = this.yForRow(Math.max(d, v.rowStart))
        const y1 = this.yForRow(Math.min(d + 1, v.rowEnd))
        if (y1 > y0) ctx.fillRect(this.mx, y0, this.mw, y1 - y0)
      }
    }

    if (this.selectedOrigCols?.size && this.colGroups) {
      ctx.fillStyle = "rgba(14, 165, 233, 0.10)"
      for (let d = 0; d < this.nDispCols; d++) {
        const group = this.colGroups[d]
        if (!group) continue
        let hit = false
        for (let i = group[0]; i <= group[1]; i++) {
          if (this.selectedOrigCols.has(i)) { hit = true; break }
        }
        if (!hit) continue
        if (d + 1 <= v.colStart || d >= v.colEnd) continue
        const x0 = this.xForCol(Math.max(d, v.colStart))
        const x1 = this.xForCol(Math.min(d + 1, v.colEnd))
        if (x1 > x0) ctx.fillRect(x0, this.my, x1 - x0, this.mh)
      }
    }
    ctx.restore()
  }

  drawActiveSelectionRect(ctx) {
    if (!this.selectionRect) return
    const x = Math.min(this.selectionRect.x0, this.selectionRect.x1)
    const y = Math.min(this.selectionRect.y0, this.selectionRect.y1)
    const w = Math.abs(this.selectionRect.x1 - this.selectionRect.x0)
    const h = Math.abs(this.selectionRect.y1 - this.selectionRect.y0)
    ctx.save()
    ctx.fillStyle = "rgba(37, 99, 235, 0.12)"
    ctx.strokeStyle = "rgba(37, 99, 235, 0.9)"
    ctx.lineWidth = 1.5
    ctx.fillRect(x, y, w, h)
    ctx.strokeRect(x, y, w, h)
    ctx.restore()
  }

  drawDendrogram(ctx, tree, axis) {
    const maxH = tree.maxHeight
    ctx.strokeStyle = "#475569"
    ctx.lineWidth = 1

    const baseAxis = this.layout.pad

    const posOf = (node) => {
      const center = this.nodeDisplayCenter(node, axis)
      if (axis === "col") {
        return { main: this.xForCol(center), depth: baseAxis + this.colTreeH * (1 - node.height / maxH) }
      }
      return { main: this.yForRow(center), depth: baseAxis + this.rowTreeW * (1 - node.height / maxH) }
    }

    const leafDepth = axis === "col" ? baseAxis + this.colTreeH : baseAxis + this.rowTreeW

    const draw = (node) => {
      if (node.leaf) {
        const center = this.nodeDisplayCenter(node, axis)
        const main = axis === "col" ? this.xForCol(center) : this.yForRow(center)
        return { main, depth: leafDepth }
      }
      const childPos = node.children.map(draw)
      const p = posOf(node)
      ctx.beginPath()
      if (axis === "col") {
        childPos.forEach((cp) => {
          ctx.moveTo(cp.main, cp.depth)
          ctx.lineTo(cp.main, p.depth)
        })
        const mains = childPos.map((cp) => cp.main)
        ctx.moveTo(Math.min(...mains), p.depth)
        ctx.lineTo(Math.max(...mains), p.depth)
      } else {
        childPos.forEach((cp) => {
          ctx.moveTo(cp.depth, cp.main)
          ctx.lineTo(p.depth, cp.main)
        })
        const mains = childPos.map((cp) => cp.main)
        ctx.moveTo(p.depth, Math.min(...mains))
        ctx.lineTo(p.depth, Math.max(...mains))
      }
      ctx.stroke()
      return p
    }

    // clip to the dendrogram + matrix span so lines don't spill over labels
    ctx.save()
    if (axis === "col") {
      ctx.beginPath(); ctx.rect(this.mx - 1, this.layout.pad, this.mw + 2, this.colTreeH); ctx.clip()
    } else {
      ctx.beginPath(); ctx.rect(this.layout.pad, this.my - 1, this.rowTreeW, this.mh + 2); ctx.clip()
    }
    draw(tree.root)
    ctx.restore()
  }

  categoricalPalette(index) {
    const palette = [
      "#4e79a7", "#f28e2b", "#59a14f", "#e15759", "#76b7b2", "#edc948",
      "#b07aa1", "#ff9da7", "#9c755f", "#bab0ac", "#86bcb6", "#d37295"
    ]
    return palette[index % palette.length]
  }

  trackColor(track, value) {
    if (value === null || value === undefined || value === "" || (typeof value === "number" && Number.isNaN(value))) {
      return this.colorIntToCss(parseNanColor(track.nanColor))
    }
    if (track.type === "numerical") {
      const t = this.trackNormalizedPosition(track, Number(value))
      const colorInt = this.interpolateGradientColor(this.activeTrackControlPoints(track), t)
      return this.colorIntToCss(colorInt)
    }
    const key = value === null || value === undefined ? null : String(value)
    if (key != null && track.categoryColors && track.categoryColors[key]) {
      return track.categoryColors[key]
    }
    if (!track._catIndex) {
      track._catIndex = {}
      let i = 0
      ;(track.categories || []).forEach((cat) => { track._catIndex[cat] = i++ })
    }
    let idx = key === null ? undefined : track._catIndex[key]
    if (idx === undefined && key !== null) {
      idx = Object.keys(track._catIndex).length
      track._catIndex[key] = idx
    }
    return this.categoricalPalette(idx ?? 0)
  }

  // Aggregate a per-original-index track value over a display group.
  aggregateTrack(track, group) {
    const [s, e] = group
    if (track.type === "numerical") {
      let sum = 0, cnt = 0
      for (let i = s; i <= e; i++) {
        const v = track.values[i]
        if (v !== null && v !== undefined && !Number.isNaN(v)) { sum += Number(v); cnt++ }
      }
      return cnt > 0 ? sum / cnt : null
    }
    const counts = {}
    let bestVal = null, bestCnt = -1
    for (let i = s; i <= e; i++) {
      const v = track.values[i]
      counts[v] = (counts[v] || 0) + 1
      if (counts[v] > bestCnt) { bestCnt = counts[v]; bestVal = v }
    }
    return bestVal
  }

  trackRefFor(axis, track) {
    const list = (axis === "column" ? this.colTracks : this.rowTracks).filter((t) => !t.loading)
    const idx = list.findIndex((t) => String(t.id) === String(track.id))
    if (idx < 0) return ""
    return axis === "column" ? `c${idx + 1}` : `r${idx + 1}`
  }

  drawTracks(ctx) {
    const L = this.layout
    const colTracks = this.colTracks.filter((t) => !t.loading)
    const rowTracks = this.rowTracks.filter((t) => !t.loading)

    ctx.save()
    ctx.beginPath(); ctx.rect(this.mx, L.pad, this.mw, this.containerH); ctx.clip()
    colTracks.forEach((track, ti) => {
      const thickness = track.thickness || L.trackH
      const y = L.pad + this.colTreeH + (this.colTrackOffsets?.[ti] || 0)
      const barplot = track.type === "numerical" && track.displayMode === "barplot"
      for (let d = 0; d < this.nDispCols; d++) {
        const x0 = this.xForCol(d)
        const x1 = this.xForCol(d + 1)
        if (x1 < this.mx || x0 > this.mx + this.mw) continue
        const w = Math.max(1, x1 - x0)
        const value = this.aggregateTrack(track, this.colGroups[d])
        if (barplot) {
          ctx.fillStyle = "#f1f5f9"
          ctx.fillRect(x0, y, w, thickness)
          if (value === null || value === undefined || Number.isNaN(Number(value))) continue
          const t = this.trackNormalizedPosition(track, Number(value))
          const barH = Math.max(1, thickness * t)
          ctx.fillStyle = this.trackColor(track, value)
          ctx.fillRect(x0, y + thickness - barH, w, barH)
        } else {
          ctx.fillStyle = this.trackColor(track, value)
          ctx.fillRect(x0, y, w, thickness)
        }
      }
    })
    ctx.restore()

    // Column track refs sit aside (right of tracks), without shifting the heatmap.
    if (colTracks.length && this.trackRefW > 0) {
      ctx.save()
      ctx.fillStyle = "#334155"
      ctx.font = "10px sans-serif"
      ctx.textAlign = "left"
      ctx.textBaseline = "middle"
      colTracks.forEach((track, ti) => {
        const thickness = track.thickness || L.trackH
        const y = L.pad + this.colTreeH + (this.colTrackOffsets?.[ti] || 0)
        const ref = this.trackRefFor("column", track)
        ctx.fillText(ref, this.mx + this.mw + 3, y + thickness / 2)
      })
      ctx.restore()
    }

    ctx.save()
    ctx.beginPath(); ctx.rect(L.pad, this.my, this.containerW, this.mh); ctx.clip()
    rowTracks.forEach((track, ti) => {
      const thickness = track.thickness || L.trackW
      const x = this.mx - this.leftTracksW + (this.rowTrackOffsets?.[ti] || 0)
      const barplot = track.type === "numerical" && track.displayMode === "barplot"
      for (let d = 0; d < this.nDispRows; d++) {
        const y0 = this.yForRow(d)
        const y1 = this.yForRow(d + 1)
        if (y1 < this.my || y0 > this.my + this.mh) continue
        const h = Math.max(1, y1 - y0)
        const value = this.aggregateTrack(track, this.rowGroups[d])
        if (barplot) {
          ctx.fillStyle = "#f1f5f9"
          ctx.fillRect(x, y0, thickness, h)
          if (value === null || value === undefined || Number.isNaN(Number(value))) continue
          const t = this.trackNormalizedPosition(track, Number(value))
          const barW = Math.max(1, thickness * t)
          ctx.fillStyle = this.trackColor(track, value)
          ctx.fillRect(x, y0, barW, h)
        } else {
          ctx.fillStyle = this.trackColor(track, value)
          ctx.fillRect(x, y0, thickness, h)
        }
      }
    })
    ctx.restore()

    // Row track refs sit aside (above matrix), without shifting the heatmap.
    if (rowTracks.length && this.trackRefH > 0) {
      ctx.save()
      ctx.fillStyle = "#334155"
      ctx.font = "10px sans-serif"
      ctx.textAlign = "center"
      ctx.textBaseline = "bottom"
      rowTracks.forEach((track, ti) => {
        const thickness = track.thickness || L.trackW
        const x = this.mx - this.leftTracksW + (this.rowTrackOffsets?.[ti] || 0)
        const ref = this.trackRefFor("row", track)
        ctx.fillText(ref, x + thickness / 2, this.my - 2)
      })
      ctx.restore()
    }
  }

  hitTestTracks(p) {
    const L = this.layout
    const colTracks = this.colTracks.filter((t) => !t.loading)
    const rowTracks = this.rowTracks.filter((t) => !t.loading)

    for (let ti = 0; ti < colTracks.length; ti++) {
      const thickness = colTracks[ti].thickness || L.trackH
      const y0 = L.pad + this.colTreeH + (this.colTrackOffsets?.[ti] || 0)
      const y1 = y0 + thickness
      if (p.y < y0 || p.y > y1 || p.x < this.mx || p.x > this.mx + this.mw) continue
      const d = Math.floor(this.colForX(p.x))
      if (d < 0 || d >= this.nDispCols) continue
      return { axis: "column", track: colTracks[ti], displayIndex: d }
    }

    for (let ti = 0; ti < rowTracks.length; ti++) {
      const thickness = rowTracks[ti].thickness || L.trackW
      const x0 = this.mx - this.leftTracksW + (this.rowTrackOffsets?.[ti] || 0)
      const x1 = x0 + thickness
      if (p.x < x0 || p.x > x1 || p.y < this.my || p.y > this.my + this.mh) continue
      const d = Math.floor(this.rowForY(p.y))
      if (d < 0 || d >= this.nDispRows) continue
      return { axis: "row", track: rowTracks[ti], displayIndex: d }
    }
    return null
  }

  updateTrackTooltip(p, hit) {
    const groups = hit.axis === "column" ? this.colGroups : this.rowGroups
    const value = this.aggregateTrack(hit.track, groups[hit.displayIndex])
    const label = hit.axis === "column" ? this.displayColLabel(hit.displayIndex) : this.displayRowLabel(hit.displayIndex)
    const displayValue = value === null || value === undefined || (typeof value === "number" && Number.isNaN(value))
      ? "n/a"
      : (typeof value === "number" ? value.toPrecision(4) : String(value))
    const ref = this.trackRefFor(hit.axis, hit.track)
    const html = `<strong>${this.escape(ref ? `${ref}  ${hit.track.name}` : hit.track.name)}</strong><br>${this.escape(label)}<br>${this.escape(displayValue)}`
    if (this.hasTooltipTarget) {
      this.tooltipTarget.innerHTML = html
      this.tooltipTarget.style.display = "block"
      this.tooltipTarget.style.left = (p.x + 12) + "px"
      this.tooltipTarget.style.top = (p.y + 12) + "px"
    }
  }

  drawLabels(ctx) {
    const v = this.view
    ctx.fillStyle = "#1f2937"
    ctx.font = "11px sans-serif"

    const rowH = this.mh / (v.rowEnd - v.rowStart)
    if (rowH >= 8) {
      ctx.textAlign = "left"
      ctx.textBaseline = "middle"
      ctx.save()
      ctx.beginPath(); ctx.rect(this.mx + this.mw, this.my, this.layout.rowLabelW, this.mh); ctx.clip()
      const start = Math.max(0, Math.floor(v.rowStart))
      const end = Math.min(this.nDispRows, Math.ceil(v.rowEnd))
      for (let d = start; d < end; d++) {
        const y = this.yForRow(d + 0.5)
        const label = this.truncate(this.displayRowLabel(d), 22)
        if (this.displayRowIsSelected(d)) {
          const textW = Math.min(this.layout.rowLabelW - 8, ctx.measureText(label).width + 6)
          const boxH = Math.min(rowH - 1, 14)
          ctx.fillStyle = "#fef08a"
          ctx.fillRect(this.mx + this.mw + 3, y - boxH / 2, Math.max(4, textW), boxH)
        }
        ctx.fillStyle = "#1f2937"
        ctx.fillText(label, this.mx + this.mw + 5, y)
      }
      ctx.restore()
    }

    const colW = this.mw / (v.colEnd - v.colStart)
    if (colW >= 7) {
      ctx.save()
      ctx.beginPath(); ctx.rect(this.mx, this.my + this.mh, this.mw, this.layout.colLabelH); ctx.clip()
      ctx.textAlign = "right"
      ctx.textBaseline = "middle"
      const start = Math.max(0, Math.floor(v.colStart))
      const end = Math.min(this.nDispCols, Math.ceil(v.colEnd))
      for (let d = start; d < end; d++) {
        const x = this.xForCol(d + 0.5)
        ctx.save()
        ctx.translate(x, this.my + this.mh + 5)
        ctx.rotate(-Math.PI / 2)
        ctx.fillText(this.truncate(this.displayColLabel(d), 12), 0, 0)
        ctx.restore()
      }
      ctx.restore()
    }
  }

  displayRowIsSelected(d) {
    if (!this.selectedOrigRows?.size || !this.rowGroups) return false
    const group = this.rowGroups[d]
    if (!group) return false
    for (let i = group[0]; i <= group[1]; i++) {
      if (this.selectedOrigRows.has(i)) return true
    }
    return false
  }

  drawSelectedGeneZoomedOutMarks(ctx) {
    if (!this.selectedOrigRows?.size || !this.rowGroups) return
    if (!this.showLabels || this.labelW <= 0) return
    const v = this.view
    const rowH = this.mh / (v.rowEnd - v.rowStart)
    // Zoomed in: yellow label backgrounds already mark selected genes.
    if (rowH >= 8) return

    const markX = this.mx + this.mw
    const markW = this.labelW
    ctx.save()
    ctx.beginPath()
    ctx.rect(markX, this.my, markW, this.mh)
    ctx.clip()
    ctx.fillStyle = "#111827"
    for (let d = 0; d < this.nDispRows; d++) {
      if (!this.displayRowIsSelected(d)) continue
      if (d + 1 <= v.rowStart || d >= v.rowEnd) continue
      const y0 = this.yForRow(Math.max(d, v.rowStart))
      const y1 = this.yForRow(Math.min(d + 1, v.rowEnd))
      const h = y1 - y0
      if (h <= 0) continue
      // Thin black tick in the right label gutter only (heatmap keeps the blue wash).
      const markH = Math.max(1, Math.min(h, 3))
      const y = y0 + (h - markH) / 2
      ctx.fillRect(markX, y, markW, markH)
    }
    ctx.restore()
  }

  displayRowLabel(d) {
    const g = this.rowGroups[d]
    if (g[0] === g[1]) return (this.meta.row_labels || [])[g[0]] || ""
    return `${(this.meta.row_labels || [])[g[0]] || g[0]} (+${g[1] - g[0]})`
  }

  displayColLabel(d) {
    const g = this.colGroups[d]
    if (g[0] === g[1]) return (this.meta.col_labels || [])[g[0]] || ""
    return `${(this.meta.col_labels || [])[g[0]] || g[0]} (+${g[1] - g[0]})`
  }

  drawLegend(ctx) {
    const x0 = this.legendLeft + 8
    const maxW = Math.max(40, this.rightLegendW - 16)
    let y = this.layout.pad + 4

    ctx.fillStyle = "#334155"
    ctx.font = "bold 11px sans-serif"
    ctx.textAlign = "left"
    ctx.textBaseline = "top"
    ctx.fillText("Gene expression level", x0, y)
    y += 16

    const barH = 12
    const barW = maxW
    const stored = this.expressionGradientState()
    const points = [...(stored.customGradientControlPoints || stored.gradientControlPoints || this.defaultHeatmapControlPoints())]
      .sort((a, b) => a.position - b.position)
    const grad = ctx.createLinearGradient(x0, 0, x0 + barW, 0)
    if (points.length) {
      points.forEach((point) => {
        grad.addColorStop(Math.min(1, Math.max(0, point.position)), this.colorIntToCss(point.color))
      })
    } else if (this.diverging) {
      grad.addColorStop(0, "#3b4dbf")
      grad.addColorStop(0.5, "#f7f7f7")
      grad.addColorStop(1, "#b5171a")
    } else {
      grad.addColorStop(0, "#450a54")
      grad.addColorStop(0.5, "#21918c")
      grad.addColorStop(1, "#fce728")
    }
    ctx.fillStyle = grad
    ctx.fillRect(x0, y, barW, barH)
    ctx.strokeStyle = (this.isHoveringLegend && this.hoveringTrackLegendKey === "expression") ? "#2563eb" : "#94a3b8"
    ctx.lineWidth = (this.isHoveringLegend && this.hoveringTrackLegendKey === "expression") ? 2 : 1
    ctx.strokeRect(x0, y, barW, barH)
    this.legendBounds = { x: x0, y, width: barW, height: barH }

    y += barH + 2
    ctx.fillStyle = "#334155"
    ctx.font = "9px sans-serif"
    ctx.textBaseline = "top"
    const mid = ((this.vmax + this.vmin) / 2).toFixed(1)
    const maxText = this.vmax.toFixed(1)
    ctx.textAlign = "left"
    ctx.fillText(this.vmin.toFixed(1), x0, y)
    ctx.textAlign = "center"
    ctx.fillText(mid, x0 + barW / 2, y)
    ctx.textAlign = "right"
    ctx.fillText(maxText, x0 + barW, y)

    this._legendTracksStartY = y + 28
  }

  drawTrackLegends(ctx) {
    const geneTracks = this.tracksWithInPlotLegends("row")
    const cellTracks = this.tracksWithInPlotLegends("column")
    this.trackLegendBounds = []
    if (!geneTracks.length && !cellTracks.length) return

    const x0 = this.legendLeft + 8
    const maxX = this.legendLeft + this.rightLegendW - this.layout.pad
    const maxW = Math.max(40, maxX - x0)
    let y = this._legendTracksStartY || (this.layout.pad + 4 + 50)

    // Shared gradient column so continuous-track bars align vertically.
    ctx.font = "9px sans-serif"
    let minLabelW = 0
    let maxLabelW = 0
    ;[...geneTracks, ...cellTracks].forEach((track) => {
      if (track.type !== "numerical") return
      const range = this.trackValueRange(track)
      minLabelW = Math.max(minLabelW, ctx.measureText(Number(range.min).toPrecision(3)).width)
      maxLabelW = Math.max(maxLabelW, ctx.measureText(Number(range.max).toPrecision(3)).width)
    })
    const barX = x0 + minLabelW + 4
    const barW = Math.max(28, Math.min(maxW - minLabelW - maxLabelW - 12, maxW * 0.7))

    ctx.save()
    ctx.beginPath()
    ctx.rect(x0 - 2, y - 4, maxW + 4, this.containerH - (y - 4) - this.layout.pad)
    ctx.clip()

    const drawSection = (title, tracks) => {
      if (!tracks.length) return
      ctx.font = "bold 11px sans-serif"
      ctx.fillStyle = "#0f172a"
      ctx.textAlign = "left"
      ctx.textBaseline = "top"
      ctx.fillText(title, x0, y)
      y += 16

      tracks.forEach((track) => {
        const ref = this.trackRefFor(track.axis, track)
        ctx.textAlign = "left"
        ctx.textBaseline = "top"
        let titleX = x0
        if (ref) {
          ctx.font = "bold 11px sans-serif"
          ctx.fillStyle = "#1d4ed8"
          ctx.fillText(ref, titleX, y)
          titleX += ctx.measureText(ref).width + 6
        }
        ctx.font = "bold 11px sans-serif"
        ctx.fillStyle = "#111827"
        const nameMaxW = Math.max(20, maxW - (titleX - x0))
        ctx.fillText(this.fitTextToWidth(ctx, track.name, nameMaxW), titleX, y)
        y += 15

        if (track.type === "numerical") {
          const range = this.trackValueRange(track)
          const minText = Number(range.min).toPrecision(3)
          const maxText = Number(range.max).toPrecision(3)
          ctx.font = "9px sans-serif"
          ctx.fillStyle = "#334155"
          ctx.textBaseline = "middle"
          ctx.textAlign = "right"
          ctx.fillText(minText, barX - 4, y + 5)
          const points = [...this.activeTrackControlPoints(track)].sort((a, b) => a.position - b.position)
          const grad = ctx.createLinearGradient(barX, 0, barX + barW, 0)
          if (points.length) {
            points.forEach((point) => {
              grad.addColorStop(
                Math.min(1, Math.max(0, point.position)),
                this.colorIntToCss(point.color)
              )
            })
          } else {
            grad.addColorStop(0, "#ffffff")
            grad.addColorStop(1, "#0000ff")
          }
          ctx.fillStyle = grad
          ctx.fillRect(barX, y, barW, 10)
          const hoverKey = `${track.axis}:${track.id}`
          const hovered = this.isHoveringLegend && this.hoveringTrackLegendKey === hoverKey
          ctx.strokeStyle = hovered ? "#2563eb" : "#cbd5e1"
          ctx.lineWidth = hovered ? 2 : 1
          ctx.strokeRect(barX, y, barW, 10)
          this.trackLegendBounds.push({
            axis: track.axis,
            track,
            bounds: { x: barX, y, width: barW, height: 10 }
          })
          ctx.fillStyle = "#334155"
          ctx.textAlign = "left"
          ctx.fillText(maxText, barX + barW + 4, y + 5)
          y += 18
          return
        }

        let x = x0
        const rowH = 14
        ctx.font = "10px sans-serif"
        ctx.textBaseline = "middle"
        track.categories.forEach((cat) => {
          const label = String(cat)
          const labelW = ctx.measureText(label).width
          const itemW = 12 + labelW + 8
          if (x > x0 && x + itemW > maxX) {
            x = x0
            y += rowH
          }
          const color = (track.categoryColors && track.categoryColors[cat])
            ? track.categoryColors[cat]
            : this.categoricalPalette(track._catIndex[cat] ?? 0)
          ctx.fillStyle = color
          ctx.fillRect(x, y + 2, 10, 10)
          ctx.strokeStyle = "#94a3b8"
          ctx.lineWidth = 1
          ctx.strokeRect(x, y + 2, 10, 10)
          ctx.fillStyle = "#334155"
          ctx.fillText(label, x + 12, y + 7)
          x += itemW
        })
        y += rowH + 8
      })
    }

    drawSection("Gene metadata tracks", geneTracks)
    if (geneTracks.length && cellTracks.length) y += 14
    drawSection("Cell metadata tracks", cellTracks)

    ctx.restore()
  }

  updateTooltip(p, e) {
    const c = Math.floor(this.colForX(p.x))
    const r = Math.floor(this.rowForY(p.y))
    if (c < 0 || c >= this.nDispCols || r < 0 || r >= this.nDispRows) { this.hideTooltip(); return }
    const gene = this.displayRowLabel(r)
    const col = this.displayColLabel(c)
    const valueText = this.formatExpressionValue(
      this.displayMatrix ? this.displayMatrix[r * this.nDispCols + c] : NaN
    )
    const html = `<strong>${this.escape(gene)}</strong><br>${this.escape(col)}<br>Expression: ${this.escape(valueText)}`
    if (this.hasTooltipTarget) {
      this.tooltipTarget.innerHTML = html
      this.tooltipTarget.style.display = "block"
      const rect = this.element.querySelector(".heatmap-canvas-area").getBoundingClientRect()
      this.tooltipTarget.style.left = (p.x + 12) + "px"
      this.tooltipTarget.style.top = (p.y + 12) + "px"
    }
  }

  formatExpressionValue(value) {
    if (value === null || value === undefined || Number.isNaN(value)) return "NA"
    const abs = Math.abs(value)
    if (abs !== 0 && (abs < 0.001 || abs >= 10000)) return value.toExponential(3)
    return Number(value.toPrecision(4)).toString()
  }

  hideTooltip() {
    if (this.hasTooltipTarget) this.tooltipTarget.style.display = "none"
  }

  truncate(s, n) {
    s = String(s == null ? "" : s)
    return s.length > n ? s.slice(0, n - 1) + "\u2026" : s
  }

  fitTextToWidth(ctx, text, maxWidth) {
    const raw = String(text == null ? "" : text)
    if (!(maxWidth > 0)) return ""
    if (ctx.measureText(raw).width <= maxWidth) return raw
    const ellipsis = "\u2026"
    const ellipsisWidth = ctx.measureText(ellipsis).width
    if (ellipsisWidth >= maxWidth) return ellipsis
    let low = 0
    let high = raw.length
    while (low < high) {
      const mid = Math.ceil((low + high) / 2)
      const candidate = raw.slice(0, mid) + ellipsis
      if (ctx.measureText(candidate).width <= maxWidth) low = mid
      else high = mid - 1
    }
    return low > 0 ? raw.slice(0, low) + ellipsis : ellipsis
  }

  escape(s) {
    const div = document.createElement("div")
    div.textContent = String(s == null ? "" : s)
    return div.innerHTML
  }

  // --- Shared gradient editor host API (used by GradientManager / ColorManager) ---

  copyControlPoints(points) {
    return (points || []).map((p) => ({
      position: Number(p.position),
      color: Number(p.color)
    }))
  }

  // Seed controller + metadataGradients so the modal loads the gradient currently shown.
  seedGradientEditorState(points, scale, metadataId, nanColor) {
    const copied = this.copyControlPoints(points)
    this.customGradientControlPoints = this.copyControlPoints(copied)
    this.gradientControlPoints = this.copyControlPoints(copied)
    this.gradientScale = scale === "log" ? "log" : "normal"
    this.nanColor = parseNanColor(nanColor)
    this.metadataGradients.set(metadataId, {
      gradientControlPoints: this.copyControlPoints(copied),
      customGradientControlPoints: this.copyControlPoints(copied),
      gradientScale: this.gradientScale,
      nanColor: nanColorToHex(this.nanColor)
    })
  }

  stashCurrentGradientEditorTarget() {
    // Persist only the active editor target from controller state — never overwrite
    // another metadata entry with unrelated controller points.
    if (!this.editingGradientTarget) return

    if (this.editingGradientTarget.type === "expression") {
      if (this.currentMetadataId === "heatmap_expression") {
        this.gradientManager.saveGradientForMetadata("heatmap_expression")
      }
      this.expressionCustomColorRange = this.customColorRange
        ? { min: this.customColorRange.min, max: this.customColorRange.max }
        : null
      return
    }

    const found = this.findTrackById(this.editingGradientTarget.id, this.editingGradientTarget.axis)
    if (found?.track) this.applyControllerGradientToTrack(found.track)
  }

  applyControllerGradientToTrack(track) {
    if (!track || track.type !== "numerical") return
    const points = this.activeControlPoints().map((p) => ({
      position: Number(p.position),
      color: Number(p.color)
    }))
    track.customGradientControlPoints = this.customGradientControlPoints
      ? this.customGradientControlPoints.map((p) => ({ position: Number(p.position), color: Number(p.color) }))
      : points
    track.gradientControlPoints = points
    track.gradientScale = this.gradientScale === "log" ? "log" : "normal"
    track.customColorRange = this.customColorRange
      ? { min: Number(this.customColorRange.min), max: Number(this.customColorRange.max) }
      : null
    track.nanColor = parseNanColor(this.nanColor)
    this.gradientManager.saveGradientForMetadata(this.trackGradientMetadataId(track))
  }

  openGradientEditorModal() {
    this.openExpressionGradientEditor()
  }

  openExpressionGradientEditor() {
    // Capture the legend's gradient before stash/load can replace controller state.
    const displayed = this.expressionGradientState()
    const points = displayed.customGradientControlPoints ||
      displayed.gradientControlPoints ||
      this.defaultHeatmapControlPoints()
    const scale = displayed.gradientScale === "log" ? "log" : "normal"

    this.stashCurrentGradientEditorTarget()
    this.editingGradientTarget = { type: "expression" }
    this.currentMetadataId = "heatmap_expression"
    if (!this.currentMetadataVector) this.setupExpressionGradient()
    const values = this.displayMatrix || this.baseMatrix
    if (values) {
      this.currentMetadataVector = {
        data_type: "NUMERIC",
        values,
        compression_info: { min_val: this.vmin, max_val: this.vmax }
      }
    }
    this.customColorRange = this.expressionCustomColorRange
      ? { ...this.expressionCustomColorRange }
      : null
    this.gradientMinValue = this.customColorRange?.min ?? this.vmin
    this.gradientMaxValue = this.customColorRange?.max ?? this.vmax
    this.seedGradientEditorState(points, scale, this.currentMetadataId, displayed.nanColor)
    const histLabel = document.getElementById("gradient-editor-hist-label")
    if (histLabel) histLabel.textContent = "Gene expression distribution"
    this.gradientManager.openGradientEditorModal()
  }

  openTrackGradientEditor(track, axis) {
    if (!track || track.type !== "numerical") return
    this.ensureTrackGradient(track)
    const points = this.activeTrackControlPoints(track)
    const scale = track.gradientScale === "log" ? "log" : "normal"

    this.stashCurrentGradientEditorTarget()
    this.editingGradientTarget = { type: "track", id: track.id, axis }
    this.currentMetadataId = this.trackGradientMetadataId(track)
    this.customColorRange = track.customColorRange
      ? { min: Number(track.customColorRange.min), max: Number(track.customColorRange.max) }
      : null
    const range = this.trackValueRange(track)
    this.gradientMinValue = range.min
    this.gradientMaxValue = range.max
    this.currentMetadataVector = {
      data_type: "NUMERIC",
      values: track.values,
      compression_info: { min_val: track.min, max_val: track.max }
    }
    this.seedGradientEditorState(points, scale, this.currentMetadataId, track.nanColor)
    const histLabel = document.getElementById("gradient-editor-hist-label")
    if (histLabel) histLabel.textContent = `${track.name} distribution`
    this.gradientManager.openGradientEditorModal()
  }

  closeGradientEditorModal() {
    this.stashCurrentGradientEditorTarget()
    this.gradientManager.closeGradientEditorModal()
    this.persistCurrentCheckpointOnServer("close-gradient-editor")
  }

  closeControlPointEditor() {
    const editor = document.getElementById("gradient-control-point-editor")
    if (editor) editor.style.display = "none"
    this.selectedControlPointIndex = undefined
    this.rendererManager.renderModalGradientPreview()
    this.rendererManager.renderModalControlPointMarkers()
    this.rendererManager.renderControlPointsList()
    this.reapplyColorsWithNewGradient()
  }

  resetGradient() {
    this.customGradientControlPoints = null
    this.selectedControlPointIndex = undefined
    this.gradientScale = "normal"
    this.nanColor = DEFAULT_NAN_COLOR_INT
    if (this.editingGradientTarget?.type === "track") {
      this.gradientControlPoints = this.defaultNumericalTrackControlPoints()
      this.customColorRange = null
    } else {
      this.colorManager.initializeDefaultGradient()
      if (!this.gradientControlPoints || !this.gradientControlPoints.length) {
        this.gradientControlPoints = this.defaultHeatmapControlPoints()
      }
      this.customColorRange = null
      this.expressionCustomColorRange = null
    }
    this.gradientManager.saveGradientForMetadata(this.currentMetadataId)
    this.closeControlPointEditor()
    this.gradientManager.syncGradientScaleSelect()
    this.gradientManager.syncNanColorInput()
    this.rendererManager.renderModalGradientPreview()
    this.rendererManager.renderModalControlPointMarkers()
    this.rendererManager.renderControlPointsList()
    this.gradientManager.renderGradientDistributionHistogram()
    this.reapplyColorsWithNewGradient()
  }

  reapplyColorsWithNewGradient() {
    if (this.currentMetadataId) {
      this.gradientManager.saveGradientForMetadata(this.currentMetadataId)
    }

    if (this.editingGradientTarget?.type === "track") {
      const found = this.findTrackById(this.editingGradientTarget.id, this.editingGradientTarget.axis)
      if (found?.track) this.applyControllerGradientToTrack(found.track)
      this.render()
    } else {
      this.expressionCustomColorRange = this.customColorRange
        ? { min: this.customColorRange.min, max: this.customColorRange.max }
        : null
      this.applyActiveColormap()
      if (this.displayMatrix && this.renderer) {
        this.renderer.setMatrix(
          this.displayMatrix,
          this.nDispRows,
          this.nDispCols,
          this.vmin,
          this.vmax,
          (v, vmin, vmax) => this.normalizeExpressionValue(v, vmin, vmax)
        )
      }
      this.render()
    }
    this.persistCurrentCheckpointOnServer("gradient-edit")
  }

  getMissingNumericColor() {
    return parseNanColor(this.nanColor)
  }

  getEffectiveColorRange() {
    if (this.customColorRange) return this.customColorRange
    if (this.editingGradientTarget?.type === "track") {
      const found = this.findTrackById(this.editingGradientTarget.id, this.editingGradientTarget.axis)
      if (found?.track) {
        return { min: Number(found.track.min), max: Number(found.track.max) }
      }
    }
    if (Number.isFinite(this.vmin) && Number.isFinite(this.vmax)) {
      return { min: this.vmin, max: this.vmax }
    }
    return null
  }

  canUseLogGradientScale(minVal, maxVal) {
    return Number.isFinite(minVal) && Number.isFinite(maxVal) && minVal > 0 && maxVal > 0
  }

  getEffectiveGradientScale(minVal = null, maxVal = null) {
    if (this.gradientScale !== "log") return "normal"
    let min = minVal
    let max = maxVal
    if (min === null || max === null) {
      const range = this.getEffectiveColorRange()
      if (range) {
        min = range.min
        max = range.max
      } else {
        min = this.gradientMinValue
        max = this.gradientMaxValue
      }
    }
    return this.canUseLogGradientScale(min, max) ? "log" : "normal"
  }

  valueToGradientPosition(value, minVal, maxVal) {
    if (!Number.isFinite(value) || !Number.isFinite(minVal) || !Number.isFinite(maxVal)) return 0
    if (this.getEffectiveGradientScale(minVal, maxVal) === "log") {
      if (value <= 0) return 0
      const logMin = Math.log10(minVal)
      const logMax = Math.log10(maxVal)
      const span = logMax - logMin
      if (span <= 0) return 0
      return Math.min(1, Math.max(0, (Math.log10(value) - logMin) / span))
    }
    const span = maxVal - minVal
    if (span === 0) return 0
    return Math.min(1, Math.max(0, (value - minVal) / span))
  }

  actualValueToPosition(actualValue) {
    if (this.gradientMinValue === undefined || this.gradientMaxValue === undefined) return actualValue
    return this.valueToGradientPosition(actualValue, this.gradientMinValue, this.gradientMaxValue)
  }

  positionToActualValue(position) {
    if (this.gradientMinValue === undefined || this.gradientMaxValue === undefined) return position
    const minVal = this.gradientMinValue
    const maxVal = this.gradientMaxValue
    if (this.getEffectiveGradientScale(minVal, maxVal) === "log") {
      const logMin = Math.log10(minVal)
      const logMax = Math.log10(maxVal)
      return Math.pow(10, logMin + position * (logMax - logMin))
    }
    return minVal + (position * (maxVal - minVal))
  }

  setGradientScale(scale) {
    const next = scale === "log" ? "log" : "normal"
    if (next === "log") {
      const range = this.getEffectiveColorRange()
      const minVal = range?.min ?? this.gradientMinValue
      const maxVal = range?.max ?? this.gradientMaxValue
      if (!this.canUseLogGradientScale(minVal, maxVal)) return false
    }
    this.gradientScale = next
    return true
  }

  safeMin(values) {
    let min = Infinity
    if (!values) return min
    for (let i = 0; i < values.length; i++) {
      const v = values[i]
      if (typeof v === "number" && Number.isFinite(v) && v < min) min = v
    }
    return min
  }

  safeMax(values) {
    let max = -Infinity
    if (!values) return max
    for (let i = 0; i < values.length; i++) {
      const v = values[i]
      if (typeof v === "number" && Number.isFinite(v) && v > max) max = v
    }
    return max
  }

  resolveHistogramOptions(options = null) {
    const fallbackScale = this.histogramScale === "log" ? "log" : "normal"
    const scale = options && Object.prototype.hasOwnProperty.call(options, "scale")
      ? (options.scale === "log" ? "log" : "normal")
      : fallbackScale
    const fallbackIgnoreZeros = this.histogramIgnoreZeros !== false
    const ignoreZeros = options && Object.prototype.hasOwnProperty.call(options, "ignoreZeros")
      ? options.ignoreZeros !== false
      : fallbackIgnoreZeros
    return { scale, ignoreZeros }
  }

  buildHistogramBins(values, minEdge, maxEdge, numBins, options = null) {
    const resolved = this.resolveHistogramOptions(options)
    const scale = resolved.scale
    const ignoreZeros = resolved.ignoreZeros
    const bins = new Array(numBins).fill(0)
    const binRanges = new Array(numBins)
    let sourceCount = 0
    if (ignoreZeros) {
      for (let i = 0; i < values.length; i++) {
        if (values[i] !== 0) sourceCount++
      }
    } else {
      sourceCount = values.length
    }

    const useLog = scale === "log" && minEdge > 0 && maxEdge > 0
    if (useLog) {
      const logMin = Math.log10(minEdge)
      const logMax = Math.log10(maxEdge)
      const span = logMax - logMin
      if (span > 0) {
        for (let i = 0; i < numBins; i++) {
          const t0 = logMin + (i / numBins) * span
          const t1 = logMin + ((i + 1) / numBins) * span
          binRanges[i] = { min: Math.pow(10, t0), max: Math.pow(10, t1) }
        }
        const invSpan = numBins / span
        for (let vi = 0; vi < values.length; vi++) {
          const v = values[vi]
          if (ignoreZeros && v === 0) continue
          if (v <= 0 || !Number.isFinite(v)) continue
          let binIndex = Math.floor((Math.log10(v) - logMin) * invSpan)
          if (binIndex < 0) binIndex = 0
          if (binIndex > numBins - 1) binIndex = numBins - 1
          bins[binIndex]++
        }
      } else {
        for (let i = 0; i < numBins; i++) binRanges[i] = { min: minEdge, max: maxEdge }
        for (let vi = 0; vi < values.length; vi++) {
          const v = values[vi]
          if (ignoreZeros && v === 0) continue
          if (v > 0 && Number.isFinite(v)) bins[0]++
        }
      }
    } else {
      const binWidth = (maxEdge - minEdge) / numBins
      for (let i = 0; i < numBins; i++) {
        binRanges[i] = { min: minEdge + i * binWidth, max: minEdge + (i + 1) * binWidth }
      }
      if (binWidth > 0) {
        const invBinWidth = 1 / binWidth
        for (let vi = 0; vi < values.length; vi++) {
          const v = values[vi]
          if (ignoreZeros && v === 0) continue
          if (!Number.isFinite(v)) continue
          let binIndex = Math.floor((v - minEdge) * invBinWidth)
          if (binIndex < 0) binIndex = 0
          if (binIndex > numBins - 1) binIndex = numBins - 1
          bins[binIndex]++
        }
      }
    }

    let maxCount = 0
    for (let i = 0; i < numBins; i++) {
      if (bins[i] > maxCount) maxCount = bins[i]
    }
    return { bins, maxCount, binRanges, sourceCount }
  }

  // --- Checkpoints (scoped to this heatmap run) ---

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content")
  }

  async saveGeneSelection(event) {
    if (event) event.preventDefault()
    if (!this.canAnalyzeValue) {
      alert("Analyze permission is required to save a gene set.")
      return
    }
    const checkedGenes = this.geneListItems.filter((item) => item.checked).map((item) => item.symbol)
    if (!checkedGenes.length) {
      alert("No checked genes to save. Search or select genes, then check the ones to include.")
      return
    }
    this.openHeatmapGeneSetModal(checkedGenes)
  }

  openHeatmapGeneSetModal(genesToSave = null) {
    const existing = document.getElementById("heatmap-gene-set-modal-overlay")
    if (existing) existing.remove()

    const template = document.getElementById("save-heatmap-gene-set-modal-template")
    if (!template?.content?.firstElementChild) {
      alert("Gene set save form is missing.")
      return
    }

    const geneSymbols = Array.isArray(genesToSave) && genesToSave.length
      ? genesToSave.map((symbol) => String(symbol))
      : this.geneListItems.filter((item) => item.checked).map((item) => item.symbol)
    if (!geneSymbols.length) {
      alert("No checked genes to save.")
      return
    }

    const overlay = template.content.firstElementChild.cloneNode(true)
    const form = overlay.querySelector('[data-role="heatmap-gene-set-form"]')
    const nameInput = overlay.querySelector('[data-role="heatmap-gene-set-name"]')
    const collectionSelect = overlay.querySelector('[data-role="heatmap-gene-set-collection"]')
    const collectionWrap = overlay.querySelector('[data-role="heatmap-gene-set-collection-wrap"]')
    const newWrap = overlay.querySelector('[data-role="heatmap-gene-set-new-collection-wrap"]')
    const newInput = overlay.querySelector('[data-role="heatmap-gene-set-new-collection"]')
    const countEl = overlay.querySelector('[data-role="heatmap-gene-set-count"]')
    const newCollectionValue = "__new_heatmap_collection__"
    const defaultCollectionName = "Heatmap selection"

    if (countEl) countEl.textContent = String(geneSymbols.length)

    const hasExisting = !!(collectionSelect && collectionSelect.querySelectorAll("option").length > 1)
    const syncNewVisibility = () => {
      const isNew = !hasExisting || (collectionSelect && collectionSelect.value === newCollectionValue)
      if (collectionWrap) collectionWrap.style.display = hasExisting ? "" : "none"
      if (newWrap) {
        newWrap.style.display = isNew ? "block" : "none"
        newWrap.style.marginTop = hasExisting && isNew ? "10px" : "0"
      }
      if (isNew && newInput && !String(newInput.value || "").trim()) {
        newInput.value = defaultCollectionName
      }
    }
    if (collectionSelect) {
      if (hasExisting) {
        const firstExisting = Array.from(collectionSelect.options).find((opt) => opt.value !== newCollectionValue)
        if (firstExisting) collectionSelect.value = firstExisting.value
      } else {
        collectionSelect.value = newCollectionValue
      }
      collectionSelect.addEventListener("change", syncNewVisibility)
    }
    syncNewVisibility()

    const close = () => overlay.remove()
    overlay.querySelectorAll('[data-role="heatmap-gene-set-close"], [data-role="heatmap-gene-set-cancel"]').forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.preventDefault()
        close()
      })
    })
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay) close()
    })

    form.addEventListener("submit", async (e) => {
      e.preventDefault()
      const cleanName = String(nameInput?.value || "").trim()
      if (!cleanName) {
        alert("Gene set name is required.")
        return
      }
      const collectionId = collectionSelect ? collectionSelect.value : newCollectionValue
      let newCollectionName = ""
      if (!collectionId || collectionId === newCollectionValue) {
        newCollectionName = String(newInput?.value || "").trim()
        if (!newCollectionName) {
          alert("Please enter a name for the new collection.")
          return
        }
      }

      const genes = geneSymbols.map((symbol) => ({ symbol: String(symbol) }))
      const submitBtn = overlay.querySelector('[data-role="heatmap-gene-set-submit"]')
      if (submitBtn) submitBtn.disabled = true
      try {
        if (this.hasGeneSelectionStatusTarget) {
          this.geneSelectionStatusTarget.textContent = "Saving gene set..."
        }
        const body = {
          name: cleanName,
          genes,
          collection_type: "from_heatmap",
          collection_id: collectionId || newCollectionValue,
          heatmap_run_id: this.runIdValue
        }
        if (newCollectionName) body.new_collection_name = newCollectionName

        const response = await fetch(`/projects/${encodeURIComponent(this.projectKeyValue)}/save_manual_gene_set`, {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
            "X-CSRF-Token": this.csrfToken() || ""
          },
          body: JSON.stringify(body)
        })
        const payload = await response.json()
        if (!response.ok || payload.status !== "ok") {
          throw new Error(payload.message || "Failed to save gene set")
        }

        // Keep dropdown options current if a new collection was created.
        if (payload.collection?.id && collectionSelect) {
          const exists = Array.from(collectionSelect.options).some((opt) => opt.value === payload.collection.id)
          if (!exists) {
            const option = document.createElement("option")
            option.value = payload.collection.id
            option.textContent = payload.collection.label || newCollectionName || defaultCollectionName
            const createOpt = collectionSelect.querySelector(`option[value="${newCollectionValue}"]`)
            if (createOpt) collectionSelect.insertBefore(option, createOpt)
            else collectionSelect.appendChild(option)
          }
          const templateSelect = document.querySelector('#save-heatmap-gene-set-modal-template [data-role="heatmap-gene-set-collection"]')
          if (templateSelect && !Array.from(templateSelect.options).some((opt) => opt.value === payload.collection.id)) {
            const option = document.createElement("option")
            option.value = payload.collection.id
            option.textContent = payload.collection.label || newCollectionName || defaultCollectionName
            const createOpt = templateSelect.querySelector(`option[value="${newCollectionValue}"]`)
            if (createOpt) templateSelect.insertBefore(option, createOpt)
            else templateSelect.appendChild(option)
            const templateWrap = document.querySelector('#save-heatmap-gene-set-modal-template [data-role="heatmap-gene-set-collection-wrap"]')
            if (templateWrap) templateWrap.style.display = ""
          }
        }

        if (payload.collection && this.geneSetCollectionsController?.upsertCollectionFromPayload) {
          this.geneSetCollectionsController.upsertCollectionFromPayload(payload.collection)
          const collectionId = String(payload.collection.id || "").trim()
          if (
            collectionId
            && this.geneSetCollectionsController.selectedCollectionId
            && String(this.geneSetCollectionsController.selectedCollectionId) === collectionId
          ) {
            this.geneSetCollectionsController.fetchCollectionItems(
              collectionId,
              this.geneSetCollectionsController.itemsFilterInput?.value || ""
            ).catch(() => {})
          }
        }
        this.setSelectionTab("gene-sets")
        if (this.hasGeneSelectionStatusTarget) {
          this.geneSelectionStatusTarget.textContent = `Saved "${cleanName}" (${genes.length} genes).`
        }
        close()
      } catch (error) {
        if (submitBtn) submitBtn.disabled = false
        if (this.hasGeneSelectionStatusTarget) {
          this.geneSelectionStatusTarget.textContent = ""
        }
        alert(error.message || "Failed to save gene set")
      }
    })

    document.body.appendChild(overlay)
    setTimeout(() => nameInput?.focus(), 50)
  }

  async saveCellSelection(event) {
    if (event) event.preventDefault()
    if (!this.canAnalyzeValue) {
      alert("Analyze permission is required to save a cell selection.")
      return
    }
    const listCols = Array.from(this.selectedCells)
      .map((v) => Number(v))
      .filter((v) => Number.isInteger(v) && v >= 0)
    if (!listCols.length) {
      alert("No cells selected to save. Select columns on the heatmap first.")
      return
    }
    if (!this.embeddingMetadataId) {
      alert("Cannot save selection: no embedding metadata is available for this loom.")
      return
    }
    const selectionName = prompt("Enter a name for this selection:")
    if (selectionName === null) return
    const cleanName = selectionName.trim()
    if (!cleanName) {
      alert("Selection name is required.")
      return
    }

    const loomFile = this.loomFile || ""
    const plotContext = {
      plot: "heatmap",
      heatmap: {
        run_id: Number(this.runIdValue) || null,
        run_num: String(this.runNumValue || this.runIdValue || ""),
        method_label: String(this.runLabelValue || "Heatmap"),
        loom_file: String(loomFile)
      }
    }
    const localItemId = `local-${Date.now()}-${Math.floor(Math.random() * 100000)}`
    const pendingItem = this.normalizeSavedCellSetItem({
      id: localItemId,
      run_id: null,
      metadata_id: null,
      name: cleanName,
      selected_count: listCols.length,
      status: "queued",
      created_at: new Date().toISOString(),
      loom_file: loomFile,
      unselected_name: "Not selected",
      selection_source: "heatmap-rect",
      plot_context: plotContext
    })
    this.savedCellSets = [pendingItem, ...(this.savedCellSets || [])]
    this.recentlyCreatedSavedCellSetId = localItemId
    this.renderSavedCellSets()
    this.startSelectionStatusPolling()

    try {
      if (this.hasCellSelectionStatusTarget) {
        this.cellSelectionStatusTarget.textContent = "Saving cell selection..."
      }
      const response = await fetch(`/projects/${encodeURIComponent(this.projectKeyValue)}/save_metadata_from_selection`, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken() || ""
        },
        body: JSON.stringify({
          selection_name: cleanName,
          embedding_metadata_id: this.embeddingMetadataId,
          loom_file: loomFile,
          list_cols: listCols,
          selection_source: "heatmap-rect",
          heatmap_run_id: this.runIdValue,
          plot_context: plotContext
        })
      })
      const payload = await response.json()
      if (!response.ok || payload.status !== "ok") {
        throw new Error(payload.message || "Failed to save cell selection")
      }

      const returnedItem = this.normalizeSavedCellSetItem(payload.item)
      if (returnedItem) {
        const idx = this.savedCellSets.findIndex((item) => String(item.id) === localItemId)
        if (idx >= 0) this.savedCellSets[idx] = returnedItem
        else this.savedCellSets.unshift(returnedItem)
        this.recentlyCreatedSavedCellSetId = String(returnedItem.id)
        this.renderSavedCellSets()
      }
      if (this.hasCellSelectionStatusTarget) {
        this.cellSelectionStatusTarget.textContent = `Saved "${cleanName}" (${listCols.length} cells).`
      }
      this.scheduleSavedCellSetsRefresh(150)
    } catch (error) {
      this.savedCellSets = (this.savedCellSets || []).filter((item) => String(item.id) !== localItemId)
      this.recentlyCreatedSavedCellSetId = null
      this.renderSavedCellSets()
      if (this.hasCellSelectionStatusTarget) {
        this.cellSelectionStatusTarget.textContent = ""
      }
      alert(error.message || "Failed to save cell selection")
    }
  }

  normalizeSavedCellSetItem(item) {
    if (!item || typeof item !== "object") return null
    const selectedCount = Number(item.selected_count ?? item.selectedCount)
    const plotContextRaw = item.plot_context || item.plotContext || null
    const selectionNumberRaw = item.selection_number ?? item.selectionNumber
    return {
      id: String(item.id || ""),
      runId: item.run_id != null ? Number(item.run_id) : (item.runId != null ? Number(item.runId) : null),
      metadataId: item.metadata_id != null ? String(item.metadata_id) : (item.metadataId != null ? String(item.metadataId) : null),
      name: item.name == null ? "" : String(item.name),
      selectedCount: Number.isFinite(selectedCount) ? selectedCount : 0,
      status: String(item.status || "queued"),
      createdAt: item.created_at ? String(item.created_at) : (item.createdAt ? String(item.createdAt) : null),
      loomFile: item.loom_file ? String(item.loom_file) : (item.loomFile ? String(item.loomFile) : null),
      unselectedName: item.unselected_name ? String(item.unselected_name) : (item.unselectedName || "Not selected"),
      selectionNumber: selectionNumberRaw != null && selectionNumberRaw !== "" ? Number(selectionNumberRaw) : null,
      selectionSource: item.selection_source ? String(item.selection_source) : (item.selectionSource ? String(item.selectionSource) : "lasso"),
      plotContext: (plotContextRaw && typeof plotContextRaw === "object") ? plotContextRaw : null,
      locked: item.locked === true
    }
  }

  setupSavedCellSetLiveUpdates() {
    this.setupSelectionStatesSubscription()
    this.startSelectionStatusPolling()
  }

  teardownSavedCellSetLiveUpdates() {
    if (this.selectionStatusPollingTimer) {
      clearInterval(this.selectionStatusPollingTimer)
      this.selectionStatusPollingTimer = null
    }
    if (this.selectionStatesRefreshTimer) {
      window.clearTimeout(this.selectionStatesRefreshTimer)
      this.selectionStatesRefreshTimer = null
    }
    if (this.selectionStatesSubscription) {
      this.selectionStatesSubscription.unsubscribe()
      this.selectionStatesSubscription = null
    }
  }

  startSelectionStatusPolling() {
    if (this.selectionStatusPollingTimer) {
      clearInterval(this.selectionStatusPollingTimer)
    }
    this.selectionStatusPollingTimer = setInterval(() => {
      const hasIncomplete = (this.savedCellSets || []).some((item) => {
        const status = String(item.status || "")
        return status === "queued" || status === "running"
      })
      if (!hasIncomplete && !this.recentlyCreatedSavedCellSetId) return
      this.refreshSavedCellSets()
    }, 3000)
  }

  setupSelectionStatesSubscription() {
    if (this.selectionStatesSubscription) return
    const projectChannelId = String(this.projectIdValue || "").trim()
    if (!projectChannelId) return

    this.selectionStatesSubscription = consumer.subscriptions.create(
      { channel: "ProjectChannel", project_id: projectChannelId },
      {
        connected: () => {
          this.scheduleSavedCellSetsRefresh(100)
        },
        received: (data) => {
          if (!data || data.event !== "selection_states_changed") return
          const messageLoomFile = String(data.loom_file || "")
          const currentLoomFile = String(this.loomFile || "")
          if (messageLoomFile && currentLoomFile && messageLoomFile !== currentLoomFile) return
          this.scheduleSavedCellSetsRefresh(100)
        }
      }
    )
  }

  scheduleSavedCellSetsRefresh(delayMs = 0) {
    if (this.selectionStatesRefreshTimer) {
      window.clearTimeout(this.selectionStatesRefreshTimer)
      this.selectionStatesRefreshTimer = null
    }
    this.selectionStatesRefreshTimer = window.setTimeout(() => {
      this.selectionStatesRefreshTimer = null
      this.refreshSavedCellSets()
    }, Math.max(0, Number(delayMs) || 0))
  }

  serverItemsMatchPendingSelection(pendingItem, serverItems) {
    if (!pendingItem || !Array.isArray(serverItems) || serverItems.length === 0) return false
    const pendingRunId = Number(pendingItem.runId)
    if (Number.isInteger(pendingRunId) && pendingRunId > 0) {
      if (serverItems.some((item) => Number(item.runId) === pendingRunId)) return true
    }
    const pendingName = String(pendingItem.name || "").trim()
    if (!pendingName) return false
    const pendingCount = Number(pendingItem.selectedCount)
    const sameName = serverItems.filter((item) => String(item.name || "").trim() === pendingName)
    if (sameName.length === 0) return false
    if (!Number.isFinite(pendingCount) || pendingCount < 0) return true
    return sameName.some((item) => Number(item.selectedCount || 0) === pendingCount)
  }

  mergeSavedCellSetsWithServer(serverItems) {
    const previousItems = Array.isArray(this.savedCellSets) ? this.savedCellSets : []
    const merged = Array.isArray(serverItems) ? [...serverItems] : []
    const mergedIds = new Set(merged.map((item) => String(item.id || "")))

    for (const previous of previousItems) {
      const previousId = String(previous?.id || "")
      if (!previousId.startsWith("local-")) continue
      if (mergedIds.has(previousId)) continue
      if (this.serverItemsMatchPendingSelection(previous, merged)) continue
      merged.unshift(previous)
      mergedIds.add(previousId)
    }

    const recentId = String(this.recentlyCreatedSavedCellSetId || "").trim()
    if (recentId) {
      const pending = previousItems.find((entry) => String(entry.id) === recentId)
      const matched = merged.find((item) => {
        if (String(item.id) === recentId) return true
        return pending ? this.serverItemsMatchPendingSelection(pending, [item]) : false
      })
      if (matched) {
        this.recentlyCreatedSavedCellSetId = String(matched.id)
        if (String(matched.status || "") === "completed" || String(matched.status || "") === "failed") {
          this.recentlyCreatedSavedCellSetId = null
        }
      }
    }

    return merged
  }

  async refreshSavedCellSets() {
    if (!this.hasSavedCellSetsListTarget || !this.projectKeyValue) return
    if (String(this.editingSavedCellSetId || "").trim().length > 0) return
    try {
      const loomFile = this.loomFile || ""
      const response = await fetch(
        `/projects/${encodeURIComponent(this.projectKeyValue)}/selection_states?loom_file=${encodeURIComponent(loomFile)}`,
        { headers: { Accept: "application/json" }, credentials: "same-origin" }
      )
      if (!response.ok) return
      const payload = await response.json()
      if (!payload || payload.status !== "ok" || !Array.isArray(payload.items)) return
      const serverItems = payload.items
        .map((item) => this.normalizeSavedCellSetItem(item))
        .filter((item) => item && item.id)
      this.savedCellSets = this.mergeSavedCellSetsWithServer(serverItems)
      this.renderSavedCellSets()
    } catch (_error) {
      // Ignore transient refresh errors.
    }
  }

  selectionSourceIconHtml(source) {
    const normalizedSource = String(source || "lasso")
    if (normalizedSource === "compose") {
      return '<span title="Composed selection" style="display:inline-flex;align-items:center;justify-content:center;color:#8b5cf6;flex:0 0 auto;line-height:0;"><i class="fas fa-object-group" style="font-size:11px;"></i></span>'
    }
    if (normalizedSource === "visible") {
      return '<i class="fas fa-filter" title="Visible filtered cells selection" style="font-size:11px;color:#059669;flex:0 0 auto;"></i>'
    }
    if (normalizedSource === "heatmap-rect") {
      return '<i class="fas fa-th" title="Heatmap selection" style="font-size:11px;color:#ea580c;flex:0 0 auto;"></i>'
    }
    return '<span title="Lasso selection" style="display:inline-flex;align-items:center;justify-content:center;color:#2563eb;flex:0 0 auto;line-height:0;"><svg width="12" height="12" viewBox="0 0 496.149 496.149" style="fill: currentColor;" xmlns="http://www.w3.org/2000/svg"><g><path d="M250.201,81.608c97.43,0,179.746,43.434,179.746,94.834c0,12.449-4.934,24.449-13.645,35.465l35.402,10.404 c8.613-14.227,13.533-29.629,13.533-45.869c0-72.965-94.463-130.123-215.037-130.123S35.164,103.477,35.164,176.442 c0,26.918,12.936,51.643,35.189,72.172c-6.951,4.502-13.756,10.502-18.836,18.984c-10.453,17.449-10.66,39.094-0.645,64.35 c9.433,23.791,7.125,32.582,5.693,35.242c-3.354,6.322-18.127,9.514-32.385,12.596c-3.486,0.758-7.035,1.531-10.582,2.371 c-9.484,2.24-15.353,11.725-13.129,21.225c1.902,8.111,9.164,13.596,17.16,13.596c1.34,0,2.709-0.16,4.068-0.467 c3.32-0.791,6.656-1.518,9.932-2.227c21.111-4.564,45.016-9.742,56.076-30.482c8.486-15.902,7.195-36.516-4.031-64.85 c-5.725-14.435-6.385-25.564-1.947-33.098c4.965-8.451,16.141-12.207,22.19-13.467c35.705,19.902,82.85,32.354,135.592,33.869 l-10.504-35.74c-87.867-5.758-158.555-46.447-158.555-94.074C70.451,125.041,152.772,81.608,250.201,81.608z"/><path d="M487.573,269.629l-222.049-65.271c-1.115-0.338-2.244-0.482-3.373-0.482c-3.113,0-6.158,1.227-8.434,3.5 c-3.096,3.08-4.258,7.613-3.018,11.789l65.271,222.102c1.34,4.613,5.352,7.982,10.143,8.5c0.453,0.047,0.891,0.064,1.322,0.064 c4.309,0,8.307-2.338,10.439-6.162l54.076-98.043l98.025-54.094c4.225-2.322,6.629-6.951,6.1-11.727 C495.561,275.018,492.201,271,487.573,269.629z"/></g></svg></span>'
  }

  selectionStatusBadgeHtml(status) {
    if (status === "running") {
      return '<span title="Saving" style="display:inline-flex;width:14px;height:14px;border:2px solid #93c5fd;border-top-color:#2563eb;border-radius:9999px;animation:spin 1s linear infinite;"></span>'
    }
    if (status === "failed") {
      return '<span title="Failed" style="display:inline-block;width:14px;height:14px;border-radius:9999px;background:#ef4444;"></span>'
    }
    if (status === "queued") {
      return '<span title="Queued" style="display:inline-block;width:14px;height:14px;border-radius:9999px;background:#f59e0b;"></span>'
    }
    return ""
  }

  savedCellSetDisplayName(item) {
    const rawName = item && item.name != null ? String(item.name).trim() : ""
    return rawName.length > 0 ? rawName : "Unnamed"
  }

  formatHeatmapSelectionOriginLines(item) {
    const source = String(item.selectionSource || item.selection_source || "")
    if (source !== "heatmap-rect") return []
    const plotContext = item.plotContext || item.plot_context || {}
    const heatmap = plotContext.heatmap || {}
    const runNum = String(heatmap.run_num || heatmap.runNum || "").trim()
    const method = String(heatmap.method_label || heatmap.methodLabel || "Heatmap").trim()
    const runId = String(heatmap.run_id || heatmap.runId || "").trim()
    const runLabel = runNum ? `#${runNum}` : (runId || "")
    const lines = []
    lines.push(`Heatmap run: ${runLabel || "unknown"}`)
    lines.push(`Method: ${method || "Heatmap"}`)
    return lines
  }

  renderHeatmapParametersHtml(itemOrHeatmap) {
    const heatmap = itemOrHeatmap?.heatmap
      || itemOrHeatmap?.plotContext?.heatmap
      || itemOrHeatmap?.plot_context?.heatmap
      || itemOrHeatmap
      || {}
    const parameters = Array.isArray(heatmap.parameters) ? heatmap.parameters : []
    if (!parameters.length) return ""
    const rows = parameters.map((entry) => {
      const label = String(entry?.label || entry?.key || "Parameter")
      const value = String(entry?.value ?? "")
      return `<div style="font-size:11px;color:#374151;margin-top:2px;"><span style="color:#6b7280;">${this.escapeHtml(label)}:</span> ${this.escapeHtml(value)}</div>`
    }).join("")
    return `
      <div style="margin-top:8px;padding-top:8px;border-top:1px solid #e5e7eb;">
        <div style="font-size:12px;font-weight:600;color:#111827;margin-bottom:4px;">Heatmap parameters</div>
        ${rows}
      </div>
    `
  }

  heatmapSelectionRunLabel(item) {
    if (!item || String(item.selectionSource || item.selection_source || "") !== "heatmap-rect") return ""
    const plotContext = item.plotContext || item.plot_context || {}
    const heatmap = plotContext.heatmap || {}
    const runNum = String(heatmap.run_num || heatmap.runNum || "").trim()
    if (runNum) return `Heatmap #${runNum}`
    const runId = String(heatmap.run_id || heatmap.runId || "").trim()
    return runId ? `Heatmap #${runId}` : "Heatmap"
  }

  heatmapSelectionRunId(item) {
    if (!item || String(item.selectionSource || item.selection_source || "") !== "heatmap-rect") return ""
    const plotContext = item.plotContext || item.plot_context || {}
    const heatmap = plotContext.heatmap || {}
    return String(heatmap.run_id || heatmap.runId || "").trim()
  }

  heatmapSelectionPageUrl(item) {
    const runId = this.heatmapSelectionRunId(item)
    const projectKey = String(this.projectKeyValue || "").trim()
    if (!runId || !projectKey) return ""
    return `/projects/${encodeURIComponent(projectKey)}?view=heatmap&run_id=${encodeURIComponent(runId)}`
  }

  heatmapSelectionOriginHtml(item) {
    const label = this.heatmapSelectionRunLabel(item)
    if (!label) return ""
    const url = this.heatmapSelectionPageUrl(item)
    if (!url) return this.escapeHtml(label)
    return `<a href="${this.escapeHtml(url)}" target="_blank" rel="noopener noreferrer" style="color:#2563eb;text-decoration:underline;" title="Open heatmap in a new tab" onclick="event.stopPropagation()">${this.escapeHtml(label)}</a>`
  }

  initializeSavedCellSetsFilterMenus() {
    const sortButton = document.getElementById("heatmap-sort-saved-selections-btn")
    const sortMenu = document.getElementById("heatmap-sort-saved-selections-menu")
    const sortBySelect = document.getElementById("heatmap-sort-saved-selections-by")
    const orderSelect = document.getElementById("heatmap-sort-saved-selections-order")
    const filterButton = document.getElementById("heatmap-filter-saved-selections-btn")
    const filterMenu = document.getElementById("heatmap-filter-saved-selections-menu")
    const searchInput = document.getElementById("heatmap-saved-selections-name-filter-input")

    if (sortButton && sortMenu && sortBySelect && orderSelect) {
      sortBySelect.value = this.savedCellSetsSortBy || "created_at"
      orderSelect.value = this.savedCellSetsSortOrder || "desc"

      if (!this.boundHeatmapSortMenuClick) {
        this.boundHeatmapSortMenuClick = (event) => {
          event.preventDefault()
          event.stopPropagation()
          if (filterMenu) filterMenu.style.display = "none"
          const isOpen = sortMenu.style.display === "block"
          sortMenu.style.display = isOpen ? "none" : "block"
        }
        sortButton.addEventListener("click", this.boundHeatmapSortMenuClick)
      }

      if (!this.boundHeatmapSortByChange) {
        this.boundHeatmapSortByChange = (event) => {
          this.savedCellSetsSortBy = String(event.target.value || "created_at")
          this.renderSavedCellSets()
        }
        sortBySelect.addEventListener("change", this.boundHeatmapSortByChange)
      }

      if (!this.boundHeatmapSortOrderChange) {
        this.boundHeatmapSortOrderChange = (event) => {
          this.savedCellSetsSortOrder = String(event.target.value || "desc")
          this.renderSavedCellSets()
        }
        orderSelect.addEventListener("change", this.boundHeatmapSortOrderChange)
      }

      if (!this.boundHeatmapSortOutsideClick) {
        this.boundHeatmapSortOutsideClick = (event) => {
          if (sortMenu.style.display !== "block") return
          if (sortMenu.contains(event.target) || sortButton.contains(event.target)) return
          sortMenu.style.display = "none"
        }
        document.addEventListener("click", this.boundHeatmapSortOutsideClick, true)
      }
    }

    if (filterButton && filterMenu && searchInput) {
      if (searchInput.value !== (this.savedCellSetsFilterQuery || "")) {
        searchInput.value = this.savedCellSetsFilterQuery || ""
      }
      this.updateSavedCellSetsFilterButtonAppearance(filterButton)
      this.updateSavedCellSetsFilterMenuState(filterMenu)

      if (!this.boundHeatmapFilterMenuClick) {
        this.boundHeatmapFilterMenuClick = (event) => {
          event.preventDefault()
          event.stopPropagation()
          if (sortMenu) sortMenu.style.display = "none"
          const isOpen = filterMenu.style.display === "block"
          filterMenu.style.display = isOpen ? "none" : "block"
        }
        filterButton.addEventListener("click", this.boundHeatmapFilterMenuClick)
      }

      if (!this.boundHeatmapFilterSearchInput) {
        this.boundHeatmapFilterSearchInput = (event) => {
          this.savedCellSetsFilterQuery = String(event.target.value || "")
          this.renderSavedCellSets()
        }
        searchInput.addEventListener("input", this.boundHeatmapFilterSearchInput)
      }

      if (!this.boundHeatmapFilterTypeClick) {
        this.boundHeatmapFilterTypeClick = (event) => {
          const option = event.target?.closest?.("[data-heatmap-filter-type-option]")
          if (!option) return
          event.preventDefault()
          event.stopPropagation()
          this.savedCellSetsFilterType = String(option.dataset.heatmapFilterTypeOption || "all")
          filterMenu.style.display = "none"
          this.updateSavedCellSetsFilterButtonAppearance(filterButton)
          this.updateSavedCellSetsFilterMenuState(filterMenu)
          this.renderSavedCellSets()
        }
        filterMenu.addEventListener("click", this.boundHeatmapFilterTypeClick)
      }

      if (!this.boundHeatmapFilterOutsideClick) {
        this.boundHeatmapFilterOutsideClick = (event) => {
          if (filterMenu.style.display !== "block") return
          if (filterMenu.contains(event.target) || filterButton.contains(event.target)) return
          filterMenu.style.display = "none"
        }
        document.addEventListener("click", this.boundHeatmapFilterOutsideClick, true)
      }
    }
  }

  teardownSavedCellSetsFilterMenus() {
    const sortButton = document.getElementById("heatmap-sort-saved-selections-btn")
    const sortBySelect = document.getElementById("heatmap-sort-saved-selections-by")
    const orderSelect = document.getElementById("heatmap-sort-saved-selections-order")
    const filterButton = document.getElementById("heatmap-filter-saved-selections-btn")
    const filterMenu = document.getElementById("heatmap-filter-saved-selections-menu")
    const searchInput = document.getElementById("heatmap-saved-selections-name-filter-input")

    if (this.boundHeatmapSortMenuClick && sortButton) {
      sortButton.removeEventListener("click", this.boundHeatmapSortMenuClick)
    }
    this.boundHeatmapSortMenuClick = null
    if (this.boundHeatmapSortByChange && sortBySelect) {
      sortBySelect.removeEventListener("change", this.boundHeatmapSortByChange)
    }
    this.boundHeatmapSortByChange = null
    if (this.boundHeatmapSortOrderChange && orderSelect) {
      orderSelect.removeEventListener("change", this.boundHeatmapSortOrderChange)
    }
    this.boundHeatmapSortOrderChange = null
    if (this.boundHeatmapSortOutsideClick) {
      document.removeEventListener("click", this.boundHeatmapSortOutsideClick, true)
    }
    this.boundHeatmapSortOutsideClick = null

    if (this.boundHeatmapFilterMenuClick && filterButton) {
      filterButton.removeEventListener("click", this.boundHeatmapFilterMenuClick)
    }
    this.boundHeatmapFilterMenuClick = null
    if (this.boundHeatmapFilterSearchInput && searchInput) {
      searchInput.removeEventListener("input", this.boundHeatmapFilterSearchInput)
    }
    this.boundHeatmapFilterSearchInput = null
    if (this.boundHeatmapFilterTypeClick && filterMenu) {
      filterMenu.removeEventListener("click", this.boundHeatmapFilterTypeClick)
    }
    this.boundHeatmapFilterTypeClick = null
    if (this.boundHeatmapFilterOutsideClick) {
      document.removeEventListener("click", this.boundHeatmapFilterOutsideClick, true)
    }
    this.boundHeatmapFilterOutsideClick = null
  }

  updateSavedCellSetsFilterButtonAppearance(button) {
    if (!button) return
    const type = String(this.savedCellSetsFilterType || "all")
    button.innerHTML = '<i class="fas fa-filter" style="font-size:12px;"></i>'
    button.title = `Filter saved cell sets: ${this.savedCellSetsFilterTypeLabel(type)}`
    if (type === "all") {
      button.style.backgroundColor = "white"
      button.style.color = "#374151"
      button.style.border = "1px solid #d1d5db"
      return
    }
    button.style.backgroundColor = "#22c55e"
    button.style.color = "white"
    button.style.border = "1px solid #22c55e"
  }

  savedCellSetsFilterTypeLabel(type) {
    const normalizedType = String(type || "all")
    if (normalizedType === "compose") return "Composed sets"
    if (normalizedType === "visible") return "Visible cells sets"
    if (normalizedType === "lasso") return "Lasso sets"
    if (normalizedType === "heatmap-rect") return "Heatmap sets"
    return "All type sets"
  }

  updateSavedCellSetsFilterMenuState(menu) {
    if (!menu) return
    const selectedType = String(this.savedCellSetsFilterType || "all")
    menu.querySelectorAll("[data-heatmap-filter-type-option]").forEach((option) => {
      const optionType = String(option.dataset.heatmapFilterTypeOption || "")
      const isSelected = optionType === selectedType
      option.style.backgroundColor = isSelected && optionType !== "all" ? "#dcfce7" : "#ffffff"
      const check = option.querySelector(`[data-heatmap-filter-check="${optionType}"]`)
      if (check) check.style.display = isSelected ? "inline-flex" : "none"
    })
  }

  getFilteredSavedCellSetItems(items) {
    const query = String(this.savedCellSetsFilterQuery || "").trim().toLowerCase()
    const type = String(this.savedCellSetsFilterType || "all")
    return (items || []).filter((item) => {
      if (type !== "all" && String(item.selectionSource || item.selection_source || "") !== type) {
        return false
      }
      if (!query) return true
      return this.savedCellSetDisplayName(item).toLowerCase().includes(query)
    })
  }

  getSortedSavedCellSetItems(items) {
    const sorted = [...(items || [])]
    const sortBy = this.savedCellSetsSortBy || "created_at"
    const order = this.savedCellSetsSortOrder === "asc" ? 1 : -1
    const createdAtValue = (item) => {
      if (!item?.createdAt) return 0
      const ts = new Date(item.createdAt).getTime()
      return Number.isFinite(ts) ? ts : 0
    }
    sorted.sort((a, b) => {
      if (sortBy === "name") {
        const cmp = this.savedCellSetDisplayName(a).toLowerCase()
          .localeCompare(this.savedCellSetDisplayName(b).toLowerCase())
        if (cmp !== 0) return cmp * order
        return (createdAtValue(a) - createdAtValue(b)) * -1
      }
      if (sortBy === "selected_count") {
        const aCount = Number(a?.selectedCount || 0)
        const bCount = Number(b?.selectedCount || 0)
        if (aCount !== bCount) return (aCount - bCount) * order
        return (createdAtValue(a) - createdAtValue(b)) * -1
      }
      return (createdAtValue(a) - createdAtValue(b)) * order
    })
    return sorted
  }

  renderSavedCellSets() {
    if (!this.hasSavedCellSetsListTarget) return
    this.initializeSavedCellSetsFilterMenus()
    const items = Array.isArray(this.savedCellSets) ? this.savedCellSets : []
    if (!items.length) {
      this.savedCellSetsListTarget.style.fontStyle = "italic"
      this.savedCellSetsListTarget.style.color = "#6b7280"
      this.savedCellSetsListTarget.innerHTML = "No cell sets yet"
      return
    }

    const filteredItems = this.getFilteredSavedCellSetItems(items)
    if (!filteredItems.length) {
      this.savedCellSetsListTarget.style.fontStyle = "italic"
      this.savedCellSetsListTarget.style.color = "#6b7280"
      this.savedCellSetsListTarget.innerHTML = "No cell sets match the current filters"
      return
    }

    const sortedItems = this.getSortedSavedCellSetItems(filteredItems)
    this.savedCellSetsListTarget.style.fontStyle = "normal"
    this.savedCellSetsListTarget.style.color = "#374151"
    this.savedCellSetsListTarget.innerHTML = sortedItems.map((item) => {
      const selectionId = this.escapeHtml(item.id)
      const selectionPrefix = item.selectionNumber ? `#${item.selectionNumber} ` : ""
      const displayName = this.escapeHtml(this.savedCellSetDisplayName(item))
      const count = Number(item.selectedCount || 0)
      const created = item.createdAt ? new Date(item.createdAt).toLocaleString() : ""
      const heatmapOriginHtml = this.heatmapSelectionOriginHtml(item)
      const countParts = [`${count.toLocaleString()} cells`]
      if (heatmapOriginHtml) countParts.push(heatmapOriginHtml)
      if (created) countParts.push(this.escapeHtml(created))
      const countText = countParts.join(" - ")
      const isLocked = item.locked === true
      const isEditing = String(this.editingSavedCellSetId || "") === String(item.id)
      const canRename = this.canAnalyzeValue && !isLocked
      const statusHtml = this.selectionStatusBadgeHtml(item.status)
      const lockHtml = isLocked
        ? `<span title="Created before publication; cannot be modified"
                 aria-label="Created before publication; cannot be modified"
                 style="display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;color:#6b7280;cursor:help;padding:0;">
             <i class="fas fa-lock" style="font-size:11px;"></i>
           </span>`
        : ""
      const deleteHtml = (this.canAnalyzeValue && !isLocked)
        ? `<button type="button"
                   data-action="heatmap#deleteSavedCellSet"
                   data-selection-id="${selectionId}"
                   title="Delete selection"
                   aria-label="Delete selection"
                   style="display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;color:#dc2626;background:none;border:none;cursor:pointer;padding:0;">
             <i class="fas fa-trash" style="font-size:12px;"></i>
           </button>`
        : ""
      const renameControls = canRename
        ? `<button type="button"
                   data-action="heatmap#startRenameSavedCellSet"
                   data-selection-id="${selectionId}"
                   title="Rename selection"
                   aria-label="Rename selection"
                   style="display:${isEditing ? "none" : "inline-flex"};align-items:center;justify-content:center;width:16px;height:16px;color:#6b7280;background:none;border:none;cursor:pointer;padding:0;flex:0 0 auto;">
             <i class="fas fa-pen" style="font-size:10px;"></i>
           </button>
           <button type="button"
                   data-action="heatmap#commitRenameSavedCellSet"
                   data-selection-id="${selectionId}"
                   title="Save name"
                   aria-label="Save name"
                   style="display:${isEditing ? "inline-flex" : "none"};align-items:center;justify-content:center;width:16px;height:16px;color:#16a34a;background:none;border:none;cursor:pointer;padding:0;flex:0 0 auto;">
             <i class="fas fa-check" style="font-size:11px;"></i>
           </button>
           <button type="button"
                   data-action="heatmap#cancelRenameSavedCellSet"
                   title="Cancel edit"
                   aria-label="Cancel edit"
                   style="display:${isEditing ? "inline-flex" : "none"};align-items:center;justify-content:center;width:16px;height:16px;color:#6b7280;background:none;border:none;cursor:pointer;padding:0;flex:0 0 auto;">
             <i class="fas fa-times" style="font-size:11px;"></i>
           </button>`
        : ""

      return `<div id="heatmap-saved-selection-row-${selectionId}"
                   data-role="saved-selection-row"
                   data-selection-id="${selectionId}"
                   data-action="click->heatmap#applySavedCellSet"
                   role="button"
                   tabindex="0"
                   style="width:100%;text-align:left;display:flex;align-items:center;justify-content:space-between;padding:8px;background-color:white;border-radius:6px;border:1px solid #e5e7eb;cursor:pointer;">
        <div style="flex:1;min-width:0;display:flex;align-items:flex-start;gap:6px;">
          <div style="flex:1;min-width:0;">
            <div style="display:flex;align-items:center;gap:6px;min-width:0;">
              ${this.selectionSourceIconHtml(item.selectionSource)}
              <div data-role="heatmap-saved-cell-set-name-display"
                   style="font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:${isEditing ? "none" : "block"};">
                ${selectionPrefix}${displayName}
              </div>
              <input type="text"
                     data-role="heatmap-saved-cell-set-name-input"
                     data-selection-id="${selectionId}"
                     data-action="click->heatmap#preventSavedCellSetRowClick keydown->heatmap#handleRenameSavedCellSetKeydown input->heatmap#trackRenameSavedCellSetInput"
                     value="${this.escapeHtml(item.name || "")}"
                     placeholder="Unnamed"
                     style="display:${isEditing ? "block" : "none"};font-size:13px;font-weight:600;min-width:0;flex:1;border:1px solid #d1d5db;border-radius:4px;padding:2px 6px;" />
              ${renameControls}
            </div>
            <div style="display:flex;align-items:center;gap:6px;">
              <button type="button"
                      data-action="click->heatmap#openSavedCellSetDetails"
                      data-selection-id="${selectionId}"
                      title="Selection details"
                      aria-label="Selection details"
                      style="display:inline-flex;align-items:center;justify-content:center;width:14px;height:14px;color:#2563eb;background:none;border:none;cursor:pointer;padding:0;flex:0 0 auto;">
                <i class="fas fa-circle-info" style="font-size:10px;"></i>
              </button>
              <div style="font-size:11px;color:#6b7280;">${countText}</div>
            </div>
          </div>
        </div>
        <div style="margin-left:8px;display:flex;align-items:center;gap:8px;flex:0 0 auto;">
          <div>${statusHtml}</div>
          ${lockHtml}
          ${deleteHtml}
        </div>
      </div>`
    }).join("")

    this.focusPendingSavedCellSetRenameInput()
  }

  preventSavedCellSetRowClick(event) {
    event.stopPropagation()
  }

  trackRenameSavedCellSetInput(event) {
    event.stopPropagation()
    this.pendingSavedCellSetName = event.currentTarget?.value || ""
  }

  startRenameSavedCellSet(event) {
    event.preventDefault()
    event.stopPropagation()
    if (!this.canAnalyzeValue) return
    const selectionId = String(event.currentTarget?.dataset?.selectionId || "").trim()
    if (!selectionId) return
    const item = (this.savedCellSets || []).find((entry) => String(entry.id) === selectionId)
    if (!item || item.locked) return
    this.editingSavedCellSetId = selectionId
    this.pendingSavedCellSetName = String(item.name || "")
    this.pendingSavedCellSetFocusId = selectionId
    this.renderSavedCellSets()
  }

  cancelRenameSavedCellSet(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    this.editingSavedCellSetId = null
    this.pendingSavedCellSetName = null
    this.pendingSavedCellSetFocusId = null
    this.renderSavedCellSets()
  }

  handleRenameSavedCellSetKeydown(event) {
    event.stopPropagation()
    if (event.key === "Enter") {
      event.preventDefault()
      this.commitRenameSavedCellSet(event)
      return
    }
    if (event.key === "Escape") {
      event.preventDefault()
      this.cancelRenameSavedCellSet(event)
      return
    }
    this.pendingSavedCellSetName = event.currentTarget?.value || ""
  }

  focusPendingSavedCellSetRenameInput() {
    const selectionId = String(this.pendingSavedCellSetFocusId || "").trim()
    if (!selectionId || !this.hasSavedCellSetsListTarget) return
    this.pendingSavedCellSetFocusId = null
    setTimeout(() => {
      const input = this.savedCellSetsListTarget.querySelector(
        `input[data-role="heatmap-saved-cell-set-name-input"][data-selection-id="${selectionId.replace(/"/g, '\\"')}"]`
      )
      if (input) {
        input.focus()
        input.select()
      }
    }, 0)
  }

  async commitRenameSavedCellSet(event) {
    event.preventDefault()
    event.stopPropagation()
    if (!this.canAnalyzeValue) return

    const closestSelectionNode = event.currentTarget?.closest?.("[data-selection-id]")
    const selectionId = String(
      event.currentTarget?.dataset?.selectionId ||
      closestSelectionNode?.dataset?.selectionId ||
      this.editingSavedCellSetId ||
      ""
    ).trim()
    if (!selectionId) return

    const input = this.hasSavedCellSetsListTarget
      ? this.savedCellSetsListTarget.querySelector(
          `input[data-role="heatmap-saved-cell-set-name-input"][data-selection-id="${selectionId.replace(/"/g, '\\"')}"]`
        )
      : null
    const nextName = input ? String(input.value || "").trim() : String(this.pendingSavedCellSetName || "").trim()
    const itemIndex = (this.savedCellSets || []).findIndex((entry) => String(entry.id) === selectionId)
    const item = itemIndex >= 0 ? this.savedCellSets[itemIndex] : null
    const previousName = itemIndex >= 0 ? String(this.savedCellSets[itemIndex].name || "") : ""

    try {
      if (itemIndex >= 0) this.savedCellSets[itemIndex].name = nextName
      this.editingSavedCellSetId = null
      this.pendingSavedCellSetName = null
      this.pendingSavedCellSetFocusId = null
      this.renderSavedCellSets()

      const response = await fetch(`/projects/${encodeURIComponent(this.projectKeyValue)}/rename_selection`, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken() || ""
        },
        body: JSON.stringify({
          selection_id: selectionId,
          new_name: nextName,
          run_id: item?.runId || null,
          metadata_id: item?.metadataId || null
        })
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok || (payload.status !== "ok" && payload.status !== "success")) {
        throw new Error(payload.message || "Failed to rename selection")
      }
      this.scheduleSavedCellSetsRefresh(100)
    } catch (error) {
      if (itemIndex >= 0) this.savedCellSets[itemIndex].name = previousName
      this.renderSavedCellSets()
      alert(error.message || "Failed to rename selection")
    }
  }

  async applySavedCellSet(event) {
    if (event) event.preventDefault()
    const selectionId = event?.currentTarget?.dataset?.selectionId
    if (!selectionId) return
    const item = (this.savedCellSets || []).find((entry) => String(entry.id) === String(selectionId))
    if (!item) return

    const status = String(item.status || "")
    if (status === "queued" || status === "running") {
      alert("This cell set is still being created. Try again when it is completed.")
      return
    }
    if (!item.metadataId) {
      alert("This cell set has no metadata yet and cannot be highlighted on the heatmap.")
      return
    }

    try {
      const mapping = await this.mapSavedCellSetToHeatmap(item)
      if (this.ensureCellToOrigColMap().size === 0) {
        alert("This heatmap does not expose cell-to-column mapping, so the cell set cannot be highlighted.")
        return
      }
      // Replace any existing live selection with this cell set.
      this.selectedCells.clear()
      this.selectedOrigCols.clear()
      for (const cellIndex of mapping.heatmapCellIndices) {
        this.selectedCells.add(cellIndex)
      }
      for (const origCol of mapping.origCols) {
        this.selectedOrigCols.add(origCol)
      }
      this.updateSelectionPanels()
      this.refreshExpandedGeneHistograms()
      this.drawOverlay()
      this.persistCurrentCheckpointOnServer("apply-saved-cell-set")
      if (this.hasCellSelectionStatusTarget) {
        const total = Number(item.selectedCount || mapping.totalInSet || 0)
        const inHeatmap = mapping.heatmapCellIndices.length
        this.cellSelectionStatusTarget.textContent =
          `Highlighted ${inHeatmap.toLocaleString()}/${total.toLocaleString()} cells from "${this.savedCellSetDisplayName(item)}".`
      }
    } catch (error) {
      console.error("[heatmap] apply saved cell set failed", error)
      alert(error.message || "Failed to highlight cell set on the heatmap")
    }
  }

  ensureCellToOrigColMap() {
    if (this._cellToOrigColMap instanceof Map) return this._cellToOrigColMap
    const map = new Map()
    const colCellIndices = this.meta?.col_cell_indices
    if (Array.isArray(colCellIndices)) {
      for (let origCol = 0; origCol < colCellIndices.length; origCol++) {
        const indices = colCellIndices[origCol]
        if (!Array.isArray(indices)) continue
        for (const idx of indices) {
          const n = Number(idx)
          if (!Number.isInteger(n) || n < 0) continue
          if (!map.has(n)) map.set(n, origCol)
        }
      }
    }
    if (map.size === 0 && Array.isArray(this.meta?.col_labels)) {
      const labels = this.meta.col_labels
      for (let origCol = 0; origCol < labels.length; origCol++) {
        const label = labels[origCol]
        if (label == null || String(label).trim() === "") continue
        const asInt = Number(label)
        if (Number.isInteger(asInt) && String(asInt) === String(label).trim()) {
          if (!map.has(asInt)) map.set(asInt, origCol)
        }
      }
    }
    this._cellToOrigColMap = map
    return map
  }

  isSelectionExcludedCategoryValue(rawValue, unselectedName) {
    if (rawValue === null || rawValue === undefined) return true
    const value = String(rawValue).trim()
    if (value.length === 0) return true
    if (value === "0") return true
    if (value === String(unselectedName || "Not selected").trim()) return true
    return false
  }

  async fetchSelectionMetadataVector(metadataId) {
    const mid = String(metadataId || "").trim()
    if (!mid) return null
    if (this.loadedMetadataVectors?.[mid]?.values?.length) {
      return this.selectionDataManager.ensureMetadataVectorValues(mid, this.loadedMetadataVectors[mid])
    }

    const loomFile = this.loomFile || ""
    const url = `/projects/${encodeURIComponent(this.projectKeyValue)}/metadata_vectors?metadata_ids=${encodeURIComponent(mid)}&loom_file=${encodeURIComponent(loomFile)}`
    const response = await fetch(url, {
      headers: { Accept: "application/json" },
      credentials: "same-origin"
    })
    if (!response.ok) {
      throw new Error(`Failed to load cell set metadata (${response.status})`)
    }
    const payload = await response.json()
    const vectorData = payload?.metadata_vectors?.[mid]
    if (!vectorData) {
      throw new Error("Cell set metadata was not found")
    }
    const normalized = this.selectionDataManager.ensureMetadataVectorValues(mid, vectorData)
    this.loadedMetadataVectors[mid] = normalized
    return normalized
  }

  async getCellIndicesForSavedCellSet(item) {
    const cacheKey = String(item?.id || "")
    if (cacheKey && this.savedCellSetCellsCache.has(cacheKey)) {
      return Array.from(this.savedCellSetCellsCache.get(cacheKey))
    }
    const metadataId = String(item?.metadataId || "").trim()
    if (!metadataId) return []

    const metadataVector = await this.fetchSelectionMetadataVector(metadataId)
    if (!metadataVector?.values || typeof metadataVector.values.length !== "number") {
      throw new Error("Cell set metadata has no values")
    }

    const unselectedName = String(item.unselectedName || "Not selected")
    const cellIndices = []
    for (let index = 0; index < metadataVector.values.length; index++) {
      const displayValue = this.selectionDataManager.getDisplayValue(metadataVector, index)
      if (!this.isSelectionExcludedCategoryValue(displayValue, unselectedName)) {
        cellIndices.push(index)
      }
    }
    if (cacheKey) this.savedCellSetCellsCache.set(cacheKey, cellIndices.slice())
    return cellIndices
  }

  async mapSavedCellSetToHeatmap(item) {
    const allCellIndices = await this.getCellIndicesForSavedCellSet(item)
    const cellToOrigCol = this.ensureCellToOrigColMap()
    const heatmapCellIndices = []
    const origCols = new Set()
    for (const cellIndex of allCellIndices) {
      if (!cellToOrigCol.has(cellIndex)) continue
      heatmapCellIndices.push(cellIndex)
      origCols.add(cellToOrigCol.get(cellIndex))
    }
    return {
      totalInSet: allCellIndices.length,
      heatmapCellIndices,
      origCols: Array.from(origCols).sort((a, b) => a - b)
    }
  }

  async openSavedCellSetDetails(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const selectionId = event?.currentTarget?.dataset?.selectionId
    if (!selectionId) return
    const item = (this.savedCellSets || []).find((entry) => String(entry.id) === String(selectionId))
    if (!item) return

    const overlay = document.getElementById("heatmap-cell-set-details-overlay")
    const summary = document.getElementById("heatmap-cell-set-details-summary")
    if (!overlay || !summary) return

    const selectionLabel = `${item.selectionNumber ? `#${item.selectionNumber} ` : ""}${this.savedCellSetDisplayName(item)}`
    const createdLabel = item.createdAt ? new Date(item.createdAt).toLocaleString() : "Unknown"
    const sourceText = item.selectionSource === "heatmap-rect"
      ? "Heatmap selection"
      : (item.selectionSource === "compose"
          ? "Composed selection"
          : (item.selectionSource === "visible"
              ? "Visible filtered cells selection"
              : "Lasso selection"))
    const originLines = this.formatHeatmapSelectionOriginLines(item)
      .map((line) => `<div style="font-size:11px;color:#6b7280;margin-top:2px;">${this.escapeHtml(line)}</div>`)
      .join("")
    const parametersHtml = this.renderHeatmapParametersHtml(item)
    const totalCount = Number(item.selectedCount || 0)
    summary.innerHTML = `
      <div style="font-size:13px;color:#111827;font-weight:600;word-break:break-word;">${this.escapeHtml(selectionLabel)}</div>
      <div data-role="heatmap-cell-set-in-heatmap-count" style="font-size:12px;color:#374151;margin-top:4px;">Final result: <span style="font-weight:600;color:#065f46;">computing...</span></div>
      <div style="font-size:11px;color:#6b7280;margin-top:2px;">Source: ${this.escapeHtml(sourceText)}</div>
      ${originLines}
      ${parametersHtml}
      <div style="font-size:11px;color:#6b7280;margin-top:2px;">Created: ${this.escapeHtml(createdLabel)}</div>
    `
    overlay.style.display = "flex"

    const countEl = summary.querySelector('[data-role="heatmap-cell-set-in-heatmap-count"]')
    try {
      const mapping = await this.mapSavedCellSetToHeatmap(item)
      const inHeatmap = mapping.heatmapCellIndices.length
      const totalInSet = Number.isFinite(mapping.totalInSet) && mapping.totalInSet > 0
        ? mapping.totalInSet
        : totalCount
      if (countEl) {
        countEl.innerHTML =
          `Final result: <span style="font-weight:600;color:#065f46;">${inHeatmap.toLocaleString()}/${totalInSet.toLocaleString()} cells</span>`
      }
    } catch (error) {
      if (countEl) {
        countEl.innerHTML =
          `Final result: <span style="font-weight:600;color:#065f46;">${totalCount.toLocaleString()} cells</span>`
      }
      console.warn("[heatmap] failed to compute cell set overlap", error)
    }
  }

  closeSavedCellSetDetails(event) {
    if (event) {
      event.preventDefault()
      if (event.type === "click" && event.target !== event.currentTarget && event.currentTarget?.id === "heatmap-cell-set-details-overlay") {
        return
      }
    }
    const overlay = document.getElementById("heatmap-cell-set-details-overlay")
    if (overlay) overlay.style.display = "none"
  }

  async deleteSavedCellSet(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (!this.canAnalyzeValue) {
      alert("Analyze permission is required to delete a cell selection.")
      return
    }
    const selectionId = event?.currentTarget?.dataset?.selectionId
    if (!selectionId) return
    const item = (this.savedCellSets || []).find((entry) => String(entry.id) === String(selectionId))
    const label = item ? this.savedCellSetDisplayName(item) : `Selection ${selectionId}`
    const hasAssociatedRun = item && Number.isInteger(item.runId) && item.runId > 0
    const confirmMessage = hasAssociatedRun
      ? `Delete ${label}? This will also delete the associated run and generated metadata.`
      : `Delete ${label}?`
    if (!window.confirm(confirmMessage)) return

    try {
      await this.executeSavedCellSetDeletion(item, selectionId)
      this.savedCellSets = (this.savedCellSets || []).filter((entry) => String(entry.id) !== String(selectionId))
      this.renderSavedCellSets()
      this.scheduleSavedCellSetsRefresh(100)
    } catch (error) {
      alert(error.message || "Failed to delete selection")
    }
  }

  async executeSavedCellSetDeletion(item, selectionId) {
    const requestBody = { selection_id: selectionId }
    const hasAssociatedRun = item && Number.isInteger(item.runId) && item.runId > 0
    if (hasAssociatedRun) requestBody.run_id = item.runId
    const response = await fetch(`/projects/${encodeURIComponent(this.projectKeyValue)}/delete_selection`, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken() || ""
      },
      body: JSON.stringify(requestBody)
    })
    const payload = await response.json().catch(() => ({}))
    const okStatus = payload.status === "ok" || payload.status === "success"
    if (!response.ok || !okStatus) {
      throw new Error(payload.message || "Failed to delete selection")
    }
  }

  async deleteAllSavedCellSets(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (!this.canAnalyzeValue) {
      alert("Analyze permission is required to delete cell selections.")
      return
    }

    const items = (this.savedCellSets || []).filter((item) => item && item.locked !== true)
    if (items.length === 0) {
      alert("No saved cell sets to delete.")
      return
    }

    const confirmed = window.confirm(`Delete all saved cell sets (${items.length})? This action cannot be undone.`)
    if (!confirmed) return

    const btn = document.getElementById("heatmap-delete-all-saved-selections-btn")
    if (btn) btn.disabled = true
    try {
      for (const item of items) {
        await this.executeSavedCellSetDeletion(item, item.id)
      }
      const deletedIds = new Set(items.map((item) => String(item.id)))
      this.savedCellSets = (this.savedCellSets || []).filter((entry) => !deletedIds.has(String(entry.id)))
      if (this.recentlyCreatedSavedCellSetId && deletedIds.has(String(this.recentlyCreatedSavedCellSetId))) {
        this.recentlyCreatedSavedCellSetId = null
      }
      this.renderSavedCellSets()
      this.scheduleSavedCellSetsRefresh(100)
    } catch (error) {
      alert(error.message || "Failed to delete all saved cell sets")
      this.scheduleSavedCellSetsRefresh(100)
    } finally {
      if (btn) btn.disabled = false
    }
  }

  checkpointsUrl(path = "") {
    const base = `/projects/${encodeURIComponent(this.projectKeyValue)}/checkpoints`
    return path ? `${base}/${encodeURIComponent(path)}` : base
  }

  checkpointsQuery() {
    const params = new URLSearchParams({
      kind: "heatmap",
      run_id: String(this.runIdValue)
    })
    return params.toString()
  }

  serializeTrackCheckpoint(track) {
    const payload = {
      id: track.id,
      thickness: track.thickness || this.layout.trackH,
      showLegend: !!track.showLegend,
      type: track.type === "numerical" ? "numerical" : "categorical",
      displayMode: track.displayMode === "barplot" ? "barplot" : "color"
    }
    if (track.source === "gene_set_membership") {
      payload.source = "gene_set_membership"
      payload.geneSetItemId = track.geneSetItemId
      payload.name = track.name
      payload.categoryColors = track.categoryColors
        ? { ...track.categoryColors }
        : { absent: "#d1d5db", present: "#2563eb" }
      return payload
    }
    if (track.type === "numerical") {
      this.ensureTrackGradient(track)
      const points = this.activeTrackControlPoints(track)
      payload.gradient = {
        controlPoints: points.map((p) => ({ position: Number(p.position), color: Number(p.color) })),
        customColorRange: track.customColorRange
          ? { min: Number(track.customColorRange.min), max: Number(track.customColorRange.max) }
          : null,
        gradientScale: track.gradientScale === "log" ? "log" : "normal",
        nanColor: nanColorToHex(track.nanColor)
      }
    }
    return payload
  }

  buildCheckpointState() {
    // Keep the live editor target synced before snapshotting.
    this.stashCurrentGradientEditorTarget()
    const expressionId = "heatmap_expression"
    const storedExpression = this.metadataGradients.get(expressionId)
    const expressionPoints = storedExpression?.customGradientControlPoints ||
      storedExpression?.gradientControlPoints ||
      this.activeControlPoints()
    return {
      version: 1,
      kind: "heatmap",
      run_id: Number(this.runIdValue),
      view: this.view ? { ...this.view } : null,
      showColTree: !!this.showColTree,
      showRowTree: !!this.showRowTree,
      showLabels: !!this.showLabels,
      legendWidthPx: this.estimateRightLegendWidth(),
      rightMarginPx: this.estimateRightMargin(),
      colTracks: this.colTracks.filter((t) => !t.loading).map((t) => this.serializeTrackCheckpoint(t)),
      rowTracks: this.rowTracks.filter((t) => !t.loading).map((t) => this.serializeTrackCheckpoint(t)),
      gradient: {
        controlPoints: Array.isArray(expressionPoints)
          ? expressionPoints.map((p) => ({ position: Number(p.position), color: Number(p.color) }))
          : [],
        customColorRange: this.expressionCustomColorRange
          ? { ...this.expressionCustomColorRange }
          : (this.customColorRange ? { ...this.customColorRange } : null),
        gradientScale: (storedExpression?.gradientScale || this.gradientScale || "normal") === "log"
          ? "log"
          : "normal",
        nanColor: nanColorToHex(storedExpression?.nanColor)
      },
      selection: {
        geneListItems: (this.geneListItems || []).map((item) => ({
          symbol: String(item.symbol),
          checked: !!item.checked,
          expanded: !!item.expanded
        })),
        selectedOrigCols: Array.from(this.selectedOrigCols || []).sort((a, b) => a - b),
        selectedCells: Array.from(this.selectedCells || []).sort((a, b) => a - b),
        activeTab: this.getCurrentBottomRightPanelSubView()
      },
      bottomRightPanel: this.buildBottomRightPanelCheckpointState()
    }
  }

  getCurrentBottomRightPanelSubView() {
    if (this.currentSelectionTab === "gene-sets" || this.currentSelectionTab === "cells") {
      return this.currentSelectionTab
    }
    const cellsContent = this.element.querySelector("#heatmap-cells-tab-content")
    if (cellsContent && cellsContent.style.display !== "none") return "cells"
    return "gene-sets"
  }

  buildBottomRightPanelCheckpointState() {
    const subView = this.getCurrentBottomRightPanelSubView()
    const geneSetsState = this.geneSetCollectionsController?.getCheckpointState?.() || null
    const panelState = { geneSetsState }
    const scrollContainer = this.getBottomRightPanelScrollContainer(subView, panelState)
    const anchorElement = this.getBottomRightPanelTopVisibleElement(scrollContainer, subView)

    return {
      subView,
      firstVisibleElementId: anchorElement?.id || null,
      scrollTop: scrollContainer ? Math.max(0, Number(scrollContainer.scrollTop || 0)) : 0,
      geneSetsState
    }
  }

  getBottomRightPanelScrollContainer(subView = null, panelState = null) {
    const normalizedSubView = subView === "gene-sets" ? "gene-sets" : this.getCurrentBottomRightPanelSubView()
    if (normalizedSubView === "gene-sets") {
      const isDetailMode = panelState?.geneSetsState?.mode === "detail"
      if (isDetailMode) return this.element.querySelector("#heatmap-gene-set-items-list")
      return this.element.querySelector("#heatmap-gene-set-collections-list")
    }
    return this.element.querySelector("#heatmap-saved-selections-list")
  }

  getBottomRightPanelTopVisibleElement(containerEl, subView) {
    if (!containerEl) return null
    const selector = (() => {
      if (subView !== "gene-sets") return '[data-role="saved-selection-row"]'
      if (containerEl.id === "heatmap-gene-set-items-list") return '[data-gene-set-item-row="true"]'
      return '[data-gene-set-collection-row="true"]'
    })()
    const candidates = Array.from(containerEl.querySelectorAll(selector))
    const containerRect = containerEl.getBoundingClientRect()
    let bestCandidate = null
    let bestDistance = Number.POSITIVE_INFINITY
    candidates.forEach((candidate) => {
      const rect = candidate.getBoundingClientRect()
      if ((rect.bottom - containerRect.top) <= 0) return
      const distance = Math.abs(rect.top - containerRect.top)
      if (distance < bestDistance) {
        bestDistance = distance
        bestCandidate = candidate
      }
    })
    return bestCandidate
  }

  async restoreBottomRightPanelState(state) {
    const panelState = state?.bottomRightPanel
    if (!panelState || typeof panelState !== "object") return
    const subView = panelState.subView === "gene-sets" ? "gene-sets" : "cells"
    this.setSelectionTab(subView)
    if (subView === "gene-sets" && panelState.geneSetsState && this.geneSetCollectionsController?.applyCheckpointState) {
      await this.geneSetCollectionsController.applyCheckpointState(panelState.geneSetsState)
    }

    const applyRestore = () => {
      const containerEl = this.getBottomRightPanelScrollContainer(subView, panelState)
      if (!containerEl) return

      const anchorId = String(panelState.firstVisibleElementId || "").trim()
      if (anchorId) {
        const anchorEl = document.getElementById(anchorId)
        if (anchorEl && containerEl.contains(anchorEl)) {
          const containerRect = containerEl.getBoundingClientRect()
          const anchorRect = anchorEl.getBoundingClientRect()
          containerEl.scrollTop = Math.max(0, Math.round((containerEl.scrollTop || 0) + (anchorRect.top - containerRect.top)))
          return
        }
      }

      if (Number.isFinite(Number(panelState.scrollTop))) {
        containerEl.scrollTop = Math.max(0, Number(panelState.scrollTop || 0))
      }
    }

    applyRestore()
    requestAnimationFrame(() => requestAnimationFrame(applyRestore))
  }

  wrapGeneSetCollectionsCheckpointHooks() {
    const gsc = this.geneSetCollectionsController
    if (!gsc || gsc._heatmapCheckpointHooksWrapped) return
    gsc._heatmapCheckpointHooksWrapped = true

    const persist = () => this.persistCurrentCheckpointOnServer("gene-sets-nav")
    const openCollectionDetail = gsc.openCollectionDetail.bind(gsc)
    gsc.openCollectionDetail = async (...args) => {
      const result = await openCollectionDetail(...args)
      persist()
      return result
    }
    const closeCollectionDetail = gsc.closeCollectionDetail.bind(gsc)
    gsc.closeCollectionDetail = (...args) => {
      const result = closeCollectionDetail(...args)
      persist()
      return result
    }
  }

  buildCurrentCheckpointPersistencePayload() {
    const state = this.buildCheckpointState()
    state.clientSavedAt = new Date().toISOString()
    return state
  }

  currentCheckpointSessionKey() {
    if (!this.projectKeyValue || !this.runIdValue) return null
    return `heatmap-current-checkpoint:${this.projectKeyValue}:${this.runIdValue}`
  }

  persistCurrentCheckpointToSession(state = null) {
    const key = this.currentCheckpointSessionKey()
    if (!key) return
    try {
      const payloadState = state || this.buildCurrentCheckpointPersistencePayload()
      sessionStorage.setItem(key, JSON.stringify({
        state: payloadState,
        saved_at: payloadState.clientSavedAt
      }))
      this._lastPersistedState = payloadState
    } catch (_e) {
      // ignore session storage failures
    }
  }

  readCurrentCheckpointFromSession() {
    const key = this.currentCheckpointSessionKey()
    if (!key) return null
    try {
      const raw = sessionStorage.getItem(key)
      if (!raw) return null
      const parsed = JSON.parse(raw)
      if (!parsed?.state || typeof parsed.state !== "object") return null
      return parsed.state
    } catch (_e) {
      return null
    }
  }

  persistCurrentCheckpointBeforeTeardown(reason) {
    if (this.currentCheckpointLoadInProgress) return
    if (!this.currentCheckpointReadyForOverwrite) return
    if (!this.renderer) return
    this.persistCurrentCheckpointToSession()
    this.persistCurrentCheckpointOnServer(reason)
  }

  persistCurrentCheckpointOnServer(reason = "unknown") {
    if (!this.canAnalyzeValue) return
    if (this.currentCheckpointLoadInProgress) return
    if (!this.currentCheckpointReadyForOverwrite) return
    if (!this.projectKeyValue || !this.runIdValue) return

    // Always snapshot the live view — never reuse a previous payload, or edits
    // (show legend, size, display mode, order, etc.) are lost on the next save.
    const state = this.buildCurrentCheckpointPersistencePayload()
    this.persistCurrentCheckpointToSession(state)

    fetch(`${this.checkpointsUrl("current")}?${this.checkpointsQuery()}`, {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin",
      keepalive: true,
      body: JSON.stringify({
        kind: "heatmap",
        run_id: this.runIdValue,
        checkpoint: {
          kind: "heatmap",
          run_id: this.runIdValue,
          state
        }
      })
    }).catch((e) => {
      console.warn("[heatmap] persist current checkpoint failed", reason, e)
    })
  }

  async loadCurrentCheckpointOnEntry() {
    this.currentCheckpointLoadInProgress = true
    this.setCheckpointLoading(true, "Loading checkpoint")
    try {
      const sessionState = this.readCurrentCheckpointFromSession()
      let serverState = null
      try {
        const response = await fetch(`${this.checkpointsUrl("current")}?${this.checkpointsQuery()}`, {
          method: "GET",
          headers: { Accept: "application/json" },
          credentials: "same-origin"
        })
        if (response.ok) {
          const payload = await response.json().catch(() => ({}))
          if (payload?.checkpoint?.state) serverState = payload.checkpoint.state
        }
      } catch (e) {
        console.warn("[heatmap] load current checkpoint failed", e)
      }

      const sessionAt = Date.parse(sessionState?.clientSavedAt || "") || 0
      const serverAt = Date.parse(serverState?.clientSavedAt || "") || 0
      const stateToApply = sessionAt > serverAt ? sessionState : (serverState || sessionState)
      if (!stateToApply) return false

      await this.applyCheckpointState(stateToApply)
      return true
    } catch (e) {
      console.warn("[heatmap] apply current checkpoint failed", e)
      return false
    } finally {
      this.currentCheckpointLoadInProgress = false
      this.setCheckpointLoading(false)
    }
  }

  openSaveCheckpointDialog() {
    if (!this.canAnalyzeValue) {
      alert("Not authorized to save checkpoints.")
      return
    }
    const overlay = document.getElementById("heatmap-checkpoint-save-overlay")
    if (!overlay) return
    this.fetchCheckpointHistory().then(() => {
      this.populateSaveCheckpointDialog()
      overlay.style.display = "flex"
      const titleInput = document.getElementById("heatmap-checkpoint-save-new-title")
      if (titleInput && this.resolveSaveCheckpointMode() === "new") titleInput.focus()
    })
  }

  closeSaveCheckpointDialog() {
    const overlay = document.getElementById("heatmap-checkpoint-save-overlay")
    if (overlay) overlay.style.display = "none"
  }

  checkpointSaveDialogBackdropClick(event) {
    if (event.target === document.getElementById("heatmap-checkpoint-save-overlay")) {
      this.closeSaveCheckpointDialog()
    }
  }

  updatableNamedCheckpoints() {
    return (this.checkpointHistory || []).filter((checkpoint) => {
      if (!checkpoint?.id) return false
      const title = String(checkpoint.title || "").trim()
      if (title === "__current_visualization_view__" || title === "__current_heatmap_view__") return false
      const commentCount = Number(checkpoint.comments_count || (Array.isArray(checkpoint.comments) ? checkpoint.comments.length : 0))
      return commentCount === 0
    })
  }

  currentHeatmapUserId() {
    const id = Number(this.currentUserIdValue)
    return Number.isFinite(id) && id > 0 ? id : null
  }

  populateSaveCheckpointDialog() {
    const eligible = this.updatableNamedCheckpoints()
    const select = document.getElementById("heatmap-checkpoint-save-existing-select")
    const existingRadio = document.getElementById("heatmap-checkpoint-save-mode-existing")
    const newRadio = document.getElementById("heatmap-checkpoint-save-mode-new")
    const existingWrap = document.getElementById("heatmap-checkpoint-save-existing-wrap")
    const emptyHint = document.getElementById("heatmap-checkpoint-save-existing-empty")
    if (!select || !existingRadio || !newRadio) return

    const currentUserId = this.currentHeatmapUserId()
    const preferredId = String(this.lastLoadedCheckpointId || "")
    const preferredExists = preferredId && eligible.some((checkpoint) => String(checkpoint.id) === preferredId)

    select.innerHTML = eligible.map((checkpoint) => {
      const ownerId = checkpoint.user_id == null ? null : Number(checkpoint.user_id)
      const ownerName = String(checkpoint.user_name || "Unknown").trim() || "Unknown"
      const mine = currentUserId != null && ownerId === currentUserId
      const ownerLabel = mine ? `${ownerName} (you)` : ownerName
      return `<option value="${this.escape(String(checkpoint.id))}">${this.escape(checkpoint.title || "Untitled")} — ${this.escape(ownerLabel)}</option>`
    }).join("")

    const hasEligible = eligible.length > 0
    existingRadio.disabled = !hasEligible
    select.disabled = !hasEligible
    if (existingWrap) existingWrap.style.opacity = hasEligible ? "1" : "0.55"
    if (emptyHint) emptyHint.style.display = hasEligible ? "none" : "block"

    if (hasEligible && preferredExists) {
      existingRadio.checked = true
      newRadio.checked = false
      select.value = preferredId
    } else {
      newRadio.checked = true
      existingRadio.checked = false
    }
    this.onSaveCheckpointModeChanged()
  }

  resolveSaveCheckpointMode() {
    const existingRadio = document.getElementById("heatmap-checkpoint-save-mode-existing")
    if (existingRadio && existingRadio.checked && !existingRadio.disabled) return "existing"
    return "new"
  }

  onSaveCheckpointModeChanged() {
    const mode = this.resolveSaveCheckpointMode()
    const newWrap = document.getElementById("heatmap-checkpoint-save-new-fields")
    const existingFields = document.getElementById("heatmap-checkpoint-save-existing-fields")
    if (newWrap) newWrap.style.display = mode === "new" ? "flex" : "none"
    if (existingFields) existingFields.style.display = mode === "existing" ? "flex" : "none"
  }

  async confirmSaveCheckpoint(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    const mode = this.resolveSaveCheckpointMode()
    if (mode === "existing") {
      const select = document.getElementById("heatmap-checkpoint-save-existing-select")
      const checkpointId = String(select?.value || "").trim()
      if (!checkpointId) {
        alert("Select a checkpoint to update.")
        return
      }
      await this.saveCheckpoint(null, { checkpointId })
      return
    }
    const titleInput = document.getElementById("heatmap-checkpoint-save-new-title")
    const normalized = String(titleInput?.value || "").trim()
    if (!normalized) {
      alert("Please provide a name for the new checkpoint.")
      return
    }
    await this.saveCheckpoint(normalized)
  }

  captureNamedCheckpointThumbnail() {
    if (!this.renderer || !this.hasWebglTarget || !this.hasOverlayTarget) {
      return null
    }

    this.render()

    const w = this.containerW
    const h = this.containerH
    const dpr = this.dpr
    if (!w || !h) return null

    const composite = document.createElement("canvas")
    composite.width = Math.max(1, Math.round(w * dpr))
    composite.height = Math.max(1, Math.round(h * dpr))
    const ctx = composite.getContext("2d")
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.fillStyle = "#ffffff"
    ctx.fillRect(0, 0, w, h)
    ctx.drawImage(this.webglTarget, this.mx, this.my, this.mw, this.mh)
    ctx.drawImage(this.overlayTarget, 0, 0, w, h)

    const jpeg = canvasToJpegThumbnailDataUrl(composite)
    return jpeg ? { heatmap: jpeg } : null
  }

  async saveCheckpoint(title, options = {}) {
    const checkpointId = options.checkpointId ? String(options.checkpointId).trim() : ""
    const state = this.buildCheckpointState()
    try {
      const thumbnails = this.captureNamedCheckpointThumbnail()
      if (thumbnails) {
        state.thumbnails = thumbnails
      }
    } catch (error) {
      console.warn("[heatmap] Failed to capture named-checkpoint thumbnail", error)
    }

    const url = checkpointId
      ? `${this.checkpointsUrl(checkpointId)}?${this.checkpointsQuery()}`
      : `${this.checkpointsUrl()}?${this.checkpointsQuery()}`
    const checkpointPayload = {
      kind: "heatmap",
      run_id: this.runIdValue,
      state
    }
    if (!checkpointId) checkpointPayload.title = title

    const response = await fetch(url, {
      method: checkpointId ? "PATCH" : "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin",
      body: JSON.stringify({
        kind: "heatmap",
        run_id: this.runIdValue,
        checkpoint: checkpointPayload
      })
    })

    if (!response.ok) {
      const errorPayload = await response.json().catch(() => ({}))
      alert(errorPayload.error || `Failed to save checkpoint (${response.status})`)
      return
    }

    const payload = await response.json()
    const checkpoint = payload.checkpoint
    this.mergeCheckpointIntoHistory(checkpoint)
    this.lastLoadedCheckpointId = checkpoint.id
    this.updateCheckpointCommentsButtonState(checkpoint.comments_count || 0)
    this.persistCurrentCheckpointOnServer("save-named-checkpoint")
    this.closeSaveCheckpointDialog()
    const titleInput = document.getElementById("heatmap-checkpoint-save-new-title")
    if (titleInput) titleInput.value = ""
  }

  mergeCheckpointIntoHistory(checkpoint) {
    if (!checkpoint) return
    const list = Array.isArray(this.checkpointHistory) ? this.checkpointHistory : []
    const idx = list.findIndex((item) => String(item.id) === String(checkpoint.id))
    if (idx >= 0) list[idx] = checkpoint
    else list.unshift(checkpoint)
    this.checkpointHistory = list
  }

  async fetchCheckpointHistory() {
    if (!this.projectKeyValue || !this.runIdValue) return
    const response = await fetch(`${this.checkpointsUrl()}?${this.checkpointsQuery()}`, {
      method: "GET",
      headers: { Accept: "application/json" },
      credentials: "same-origin"
    })
    if (!response.ok) return
    const payload = await response.json()
    this.checkpointHistory = Array.isArray(payload.checkpoints) ? payload.checkpoints : []
    this.currentAutoCheckpoint = payload.current_checkpoint || null
    this.updateCheckpointCommentsButtonState(
      this.checkpointForId(this.lastLoadedCheckpointId)?.comments_count || 0
    )
  }

  checkpointForId(id) {
    if (!id) return null
    return (this.checkpointHistory || []).find((item) => String(item.id) === String(id)) || null
  }

  updateCheckpointCommentsButtonState(commentCount = 0) {
    if (!this.hasCheckpointCommentsBtnTarget) return
    const count = Number(commentCount) || 0
    this.checkpointCommentsBtnTarget.style.color = count > 0 ? "#047857" : ""
    this.checkpointCommentsBtnTarget.title = count > 0
      ? `Comments (${count})`
      : "Comments on the loaded checkpoint"
  }

  async openCheckpointHistory(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (!this.hasCheckpointHistoryOverlayTarget) return
    this.checkpointHistoryOverlayTarget.style.display = "flex"
    this.setCheckpointHistoryLoading(true)
    try {
      await this.fetchCheckpointHistory()
      this.renderCheckpointHistory()
    } finally {
      this.setCheckpointHistoryLoading(false)
    }
  }

  closeCheckpointHistory() {
    if (!this.hasCheckpointHistoryOverlayTarget) return
    this.checkpointHistoryOverlayTarget.style.display = "none"
  }

  checkpointHistoryBackdropClick(event) {
    if (event.target === this.checkpointHistoryOverlayTarget) this.closeCheckpointHistory()
  }

  setCheckpointHistoryLoading(isLoading) {
    if (this.hasCheckpointHistoryLoadingTarget) {
      this.checkpointHistoryLoadingTarget.style.display = isLoading ? "flex" : "none"
    }
    if (this.hasCheckpointHistoryListTarget) {
      this.checkpointHistoryListTarget.style.display = isLoading ? "none" : "block"
    }
  }

  renderCheckpointHistory() {
    if (!this.hasCheckpointHistoryListTarget) return
    const list = this.checkpointHistoryListTarget
    const canEdit = this.canEditValue === true
    list.classList.toggle("is-readonly", !canEdit)
    const history = this.checkpointHistory || []
    const currentAuto = this.currentAutoCheckpoint
    if (!history.length && !currentAuto) {
      list.innerHTML = `
        <div style="padding:12px; color:#6b7280; line-height:1.45;">
          <div style="font-size:13px; color:#6b7280;">No checkpoints yet for this heatmap run.</div>
          <div style="margin-top:10px; font-size:12px; color:#6b7280;">
            Create a new checkpoint from the Save checkpoint control in the toolbar.
          </div>
          <div style="margin-top:10px; font-size:12px; color:#6b7280; font-weight:600;">
            Why create checkpoints:
          </div>
          <ul style="margin:6px 0 0 18px; padding:0; font-size:12px; color:#6b7280;">
            <li>Share direct links to an exact heatmap view.</li>
            ${canEdit ? "<li>Set the project landing page to a specific view.</li>" : ""}
            <li>Preserve tracks, gradients, and selections.</li>
            <li>Collaborate with comments on the same heatmap view.</li>
          </ul>
        </div>
      `
      return
    }

    const currentRowHtml = currentAuto ? this.renderCurrentAutoCheckpointRow(currentAuto) : ""
    const rowsHtml = history.map((checkpoint) => this.renderNamedCheckpointHistoryRow(checkpoint)).join("")
    const emptyNamedHtml = history.length === 0
      ? `<div style="padding:10px 12px;font-size:12px;color:#6b7280;">No named checkpoints yet.</div>`
      : ""

    list.innerHTML = `
      <div class="checkpoint-history-header">
        <div class="checkpoint-history-header-cell">Preview</div>
        <div class="checkpoint-history-header-cell">Checkpoint</div>
        ${canEdit ? `
        <div class="checkpoint-history-header-cell is-center">
          <span style="display:block;">Use as</span>
          <span style="display:block;">landing page</span>
        </div>` : ""}
        <div class="checkpoint-history-header-cell is-center">
          <span style="display:block;">Without</span>
          <span style="display:block;">comments</span>
        </div>
        <div class="checkpoint-history-header-cell is-center">
          <span style="display:block;">With</span>
          <span style="display:block;">comments</span>
        </div>
        ${canEdit ? `<div class="checkpoint-history-header-cell is-center">Delete</div>` : ""}
      </div>
      ${currentRowHtml}
      ${rowsHtml}
      ${emptyNamedHtml}
    `
  }

  checkpointHistoryThumbnailHtml(checkpoint) {
    const heatmapThumb = checkpoint?.state?.thumbnails?.heatmap
    return isCheckpointThumbnailDataUrl(heatmapThumb)
      ? `<img class="checkpoint-thumb" src="${heatmapThumb}" alt="" style="width:72px;height:54px;object-fit:cover;border:1px solid #e5e7eb;border-radius:4px;background:#fff;flex-shrink:0;" />`
      : ""
  }

  renderCurrentAutoCheckpointRow(checkpoint) {
    const updatedAt = checkpoint.updated_at ? new Date(checkpoint.updated_at).toLocaleString() : ""
    const thumbHtml = this.checkpointHistoryThumbnailHtml(checkpoint)
    const canEdit = this.canEditValue === true
    const resetCell = canEdit
      ? `<div class="checkpoint-history-cell is-center is-delete">
          <span class="checkpoint-history-field-label">Reset</span>
          <button type="button"
                  data-action="heatmap#resetCurrentCheckpoint"
                  style="border:1px solid #d1d5db;background:#fff;color:#374151;border-radius:6px;padding:4px 8px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap;"
                  title="Clear the auto-saved view and reload the default heatmap">
            Reset
          </button>
        </div>`
      : ""
    return `
      <div class="checkpoint-history-row is-current">
        <div class="checkpoint-history-preview">
          ${thumbHtml || ""}
        </div>
        <div class="checkpoint-history-meta">
          <div title="Current auto checkpoint" style="font-size:13px;font-weight:600;color:#111827;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">Current auto checkpoint</div>
          <div style="font-size:11px;color:#6b7280;">Auto-saved ${this.escape(updatedAt)}${canEdit ? ". Reset if the view looks wrong after data changes." : "."}</div>
        </div>
        ${canEdit ? '<div class="checkpoint-history-cell"></div>' : ""}
        <div class="checkpoint-history-cell"></div>
        <div class="checkpoint-history-cell"></div>
        ${resetCell}
      </div>
    `
  }

  renderNamedCheckpointHistoryRow(checkpoint) {
    const id = String(checkpoint.id)
    const createdAt = checkpoint.created_at ? new Date(checkpoint.created_at).toLocaleString() : ""
    const commentCount = Number(checkpoint.comments_count || 0)
    const thumbHtml = this.checkpointHistoryThumbnailHtml(checkpoint)
    const escapedId = this.escape(id)
    const canEdit = this.canEditValue === true
    const renameBtn = canEdit
      ? `<button type="button"
                data-action="heatmap#editCheckpointTitleFromHistory"
                data-heatmap-id-param="${escapedId}"
                title="Edit checkpoint name"
                aria-label="Edit checkpoint name"
                style="display:inline-flex;align-items:center;justify-content:center;width:16px;height:16px;color:#6b7280;background:none;border:none;cursor:pointer;padding:0;flex-shrink:0;">
            <i class="fas fa-pen" style="font-size:10px;" aria-hidden="true"></i>
          </button>`
      : ""
    const landingCell = canEdit
      ? `<div class="checkpoint-history-cell is-center is-inline">
          <span class="checkpoint-history-field-label">Use as landing page</span>
          <input type="checkbox"
                 data-action="change->heatmap#toggleCheckpointLandingPageFromHistory"
                 data-heatmap-id-param="${escapedId}"
                 ${checkpoint.is_landing_page === true ? "checked" : ""}
                 style="width:14px;height:14px;cursor:pointer;" />
        </div>`
      : ""
    const deleteCell = canEdit
      ? `<div class="checkpoint-history-cell is-center is-delete">
          <span class="checkpoint-history-field-label">Delete</span>
          <button type="button"
                  data-action="heatmap#deleteCheckpointFromHistory"
                  data-heatmap-id-param="${escapedId}"
                  style="border:1px solid #fecaca;background:#fff;color:#b91c1c;border-radius:6px;padding:4px 8px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap;">
            Delete
          </button>
        </div>`
      : ""

    return `
      <div class="checkpoint-history-row">
        <div class="checkpoint-history-preview">
          ${thumbHtml || ""}
        </div>
        <div class="checkpoint-history-meta">
          <div style="display:flex;align-items:center;gap:6px;min-width:0;">
            <div title="${this.escape(checkpoint.title || "")}" style="font-size:13px;font-weight:600;color:#111827;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0;">${this.escape(checkpoint.title || "Untitled")}</div>
            ${renameBtn}
          </div>
          <div style="font-size:11px;color:#6b7280;">${this.escape(createdAt)} - ${commentCount} comment${commentCount === 1 ? "" : "s"}</div>
        </div>
        ${landingCell}
        <div class="checkpoint-history-cell is-center">
          <span class="checkpoint-history-field-label">Without comments</span>
          <div class="checkpoint-history-btn-row">
            <button type="button"
                    data-action="heatmap#copyCheckpointDirectLinkFromHistory"
                    data-heatmap-id-param="${escapedId}"
                    data-heatmap-with-comments-param="false"
                    style="border:1px solid #d1d5db;background:#fff;color:#374151;border-radius:6px;padding:4px 8px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap;"
                    title="Copy direct link without comments">
              Copy link
            </button>
            <button type="button"
                    data-action="heatmap#loadCheckpointFromHistory"
                    data-heatmap-id-param="${escapedId}"
                    style="border:1px solid #d1d5db;background:#fff;color:#374151;border-radius:6px;padding:4px 8px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap;">
              Open
            </button>
          </div>
        </div>
        <div class="checkpoint-history-cell is-center">
          <span class="checkpoint-history-field-label">With comments</span>
          <div class="checkpoint-history-btn-row">
            <button type="button"
                    data-action="heatmap#copyCheckpointDirectLinkFromHistory"
                    data-heatmap-id-param="${escapedId}"
                    data-heatmap-with-comments-param="true"
                    style="border:1px solid #d1d5db;background:#fff;color:#374151;border-radius:6px;padding:4px 8px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap;"
                    title="Copy direct link and open comments">
              Copy link
            </button>
            <button type="button"
                    data-action="heatmap#loadCheckpointCommentsFromHistory"
                    data-heatmap-id-param="${escapedId}"
                    style="border:1px solid #d1d5db;background:#fff;color:#374151;border-radius:6px;padding:4px 8px;cursor:pointer;font-size:12px;font-weight:500;white-space:nowrap;">
              Open
            </button>
          </div>
        </div>
        ${deleteCell}
      </div>
    `
  }

  copyCheckpointDirectLinkFromHistory(event) {
    const id = event.params.id
    if (!id) return
    const withComments = event.params.withComments === true || event.params.withComments === "true"
    const button = event.currentTarget

    const url = new URL(window.location.href)
    url.searchParams.set("view", "heatmap")
    if (this.runIdValue) url.searchParams.set("run_id", String(this.runIdValue))
    url.searchParams.set("heatmap_checkpoint_id", String(id))
    if (withComments) {
      url.searchParams.set("open_heatmap_comments", "1")
    } else {
      url.searchParams.delete("open_heatmap_comments")
    }

    navigator.clipboard.writeText(url.toString()).then(() => {
      if (button) {
        const originalTitle = button.title
        button.title = "Copied!"
        setTimeout(() => {
          button.title = originalTitle || "Copy direct link to clipboard"
        }, 2000)
      }
    }).catch(() => {
      alert("Failed to copy checkpoint link to clipboard.")
    })
  }

  async toggleCheckpointLandingPageFromHistory(event) {
    const id = event.params.id
    if (!id || !this.canEditValue) return

    const checkboxEl = event.currentTarget
    const isLandingPage = !!checkboxEl?.checked
    if (checkboxEl) checkboxEl.disabled = true

    try {
      const response = await fetch(`${this.checkpointsUrl(id)}?${this.checkpointsQuery()}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        credentials: "same-origin",
        body: JSON.stringify({
          kind: "heatmap",
          run_id: this.runIdValue,
          checkpoint: { is_landing_page: isLandingPage }
        })
      })

      if (!response.ok) {
        const errorPayload = await response.json().catch(() => ({}))
        alert(errorPayload.error || "Failed to update landing page checkpoint.")
        await this.fetchCheckpointHistory()
        this.renderCheckpointHistory()
        return
      }

      await this.fetchCheckpointHistory()
      this.renderCheckpointHistory()
    } finally {
      if (checkboxEl) checkboxEl.disabled = false
    }
  }

  async loadCheckpointFromHistory(event) {
    const id = event.params.id
    await this.loadCheckpointById(id)
    this.closeCheckpointHistory()
  }

  async loadCheckpointCommentsFromHistory(event) {
    const id = event.params.id
    await this.loadCheckpointById(id)
    this.closeCheckpointHistory()
    await this.openCheckpointComments()
  }

  async deleteCheckpointFromHistory(event) {
    const id = event.params.id
    if (!this.canEditValue) return
    if (!window.confirm("Delete this checkpoint?")) return
    const response = await fetch(`${this.checkpointsUrl(id)}?${this.checkpointsQuery()}`, {
      method: "DELETE",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin"
    })
    if (!response.ok) {
      const errorPayload = await response.json().catch(() => ({}))
      alert(errorPayload.error || `Failed to delete checkpoint (${response.status})`)
      return
    }
    this.checkpointHistory = (this.checkpointHistory || []).filter((item) => String(item.id) !== String(id))
    if (String(this.lastLoadedCheckpointId) === String(id)) {
      this.lastLoadedCheckpointId = null
      this.updateCheckpointCommentsButtonState(0)
    }
    this.renderCheckpointHistory()
  }

  async editCheckpointTitleFromHistory(event) {
    const id = event.params.id
    if (!this.canEditValue) return

    const checkpoint = this.checkpointForId(id)
    if (!checkpoint) return

    const currentTitle = String(checkpoint.title || "").trim()
    const nextTitleRaw = window.prompt("Edit checkpoint name", currentTitle)
    if (nextTitleRaw === null) return

    const nextTitle = String(nextTitleRaw).trim()
    if (!nextTitle) {
      alert("Checkpoint name cannot be empty.")
      return
    }
    if (nextTitle === currentTitle) return

    const response = await fetch(`${this.checkpointsUrl(id)}?${this.checkpointsQuery()}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin",
      body: JSON.stringify({
        kind: "heatmap",
        run_id: this.runIdValue,
        checkpoint: { title: nextTitle }
      })
    })

    if (!response.ok) {
      const errorPayload = await response.json().catch(() => ({}))
      alert(errorPayload.error || `Failed to update checkpoint name (${response.status})`)
      return
    }

    const payload = await response.json()
    const updated = payload.checkpoint || { ...checkpoint, title: nextTitle }
    this.mergeCheckpointIntoHistory(updated)
    this.renderCheckpointHistory()
    this.renderCheckpointComments()
  }

  clearCurrentCheckpointFromSession() {
    const key = this.currentCheckpointSessionKey()
    if (!key) return
    try {
      sessionStorage.removeItem(key)
    } catch (_e) {
      // Session storage may be unavailable.
    }
    this._lastPersistedState = null
  }

  async resetCurrentCheckpoint() {
    if (!this.canEditValue) return
    if (!window.confirm("Reset the current auto-saved heatmap view? The page will reload without that saved state.")) {
      return
    }

    this.currentCheckpointReadyForOverwrite = false
    this.currentCheckpointLoadInProgress = true
    const response = await fetch(`${this.checkpointsUrl("current")}?${this.checkpointsQuery()}`, {
      method: "DELETE",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin"
    })
    if (!response.ok) {
      this.currentCheckpointLoadInProgress = false
      this.currentCheckpointReadyForOverwrite = true
      const errorPayload = await response.json().catch(() => ({}))
      alert(errorPayload.error || `Failed to reset the current checkpoint (${response.status})`)
      return
    }

    this.clearCurrentCheckpointFromSession()
    this.currentAutoCheckpoint = null
    window.location.reload()
  }

  setCheckpointLoading(visible, message = "Loading checkpoint") {
    if (!this.hasCheckpointLoadingOverlayTarget) return
    if (this.hasCheckpointLoadingMessageTarget) {
      const trimmed = message != null ? String(message).trim() : ""
      this.checkpointLoadingMessageTarget.textContent = trimmed.length > 0 ? trimmed : "Loading checkpoint"
    }
    this.checkpointLoadingOverlayTarget.style.display = visible ? "flex" : "none"
  }

  async loadCheckpointFromUrlIfPresent() {
    const params = new URLSearchParams(window.location.search)
    const checkpointId = String(params.get("heatmap_checkpoint_id") || "").trim()
    if (!checkpointId) return false
    await this.loadCheckpointById(checkpointId)
    if (["1", "true", "yes"].includes(String(params.get("open_heatmap_comments") || "").toLowerCase())) {
      await this.openCheckpointComments()
    }
    return true
  }

  async loadCheckpointById(checkpointId) {
    if (!checkpointId) return
    this.setCheckpointLoading(true, "Loading checkpoint")
    this.currentCheckpointLoadInProgress = true
    try {
      const response = await fetch(`${this.checkpointsUrl(checkpointId)}?${this.checkpointsQuery()}`, {
        method: "GET",
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) {
        const errorPayload = await response.json().catch(() => ({}))
        throw new Error(errorPayload.error || `Failed to load checkpoint (${response.status})`)
      }
      const payload = await response.json()
      const checkpoint = payload.checkpoint
      if (!checkpoint?.state) throw new Error("Checkpoint has no state")
      if (checkpoint.kind && checkpoint.kind !== "heatmap") {
        throw new Error("This checkpoint is not a heatmap checkpoint")
      }
      if (checkpoint.run_id && String(checkpoint.run_id) !== String(this.runIdValue)) {
        throw new Error("Checkpoint belongs to a different heatmap run")
      }

      await this.applyCheckpointState(checkpoint.state)
      this.mergeCheckpointIntoHistory(checkpoint)
      this.lastLoadedCheckpointId = checkpoint.id
      this.checkpointCommentsFocusId = checkpoint.id
      const commentCount = Number(checkpoint.comments_count || (checkpoint.comments || []).length || 0)
      this.updateCheckpointCommentsButtonState(commentCount)

      const url = new URL(window.location.href)
      url.searchParams.set("heatmap_checkpoint_id", String(checkpoint.id))
      window.history.replaceState({}, "", url.toString())
    } catch (e) {
      console.error("[heatmap] load checkpoint failed", e)
      alert(e.message || "Failed to load checkpoint")
    } finally {
      this.currentCheckpointLoadInProgress = false
      this.setCheckpointLoading(false)
      if (this.currentCheckpointReadyForOverwrite) {
        this.persistCurrentCheckpointOnServer("load-named-checkpoint")
      }
    }
  }

  async applyCheckpointState(state) {
    if (!state || typeof state !== "object") return

    this.showColTree = state.showColTree !== false
    this.showRowTree = state.showRowTree !== false
    this.showLabels = state.showLabels !== false
    if (Number.isFinite(Number(state.legendWidthPx))) {
      this.legendWidthPx = Number(state.legendWidthPx)
      this.syncLegendWidthControls()
    }
    if (Number.isFinite(Number(state.rightMarginPx))) {
      this.rightMarginPx = Number(state.rightMarginPx)
      this.syncRightMarginControls()
    }
    this.syncToggleButtons()

    this.colTracks = []
    this.rowTracks = []
    const colSpecs = Array.isArray(state.colTracks) ? state.colTracks : []
    const rowSpecs = Array.isArray(state.rowTracks) ? state.rowTracks : []
    for (const spec of colSpecs) {
      await this.restoreTrack(spec, "column")
    }
    for (const spec of rowSpecs) {
      await this.restoreTrack(spec, "row")
    }
    this.renderActiveTracksList()

    this.rebuildDisplay()

    if (state.view && typeof state.view === "object") {
      this.view = {
        colStart: Number(state.view.colStart) || 0,
        colEnd: Number(state.view.colEnd) || this.nDispCols,
        rowStart: Number(state.view.rowStart) || 0,
        rowEnd: Number(state.view.rowEnd) || this.nDispRows
      }
    } else {
      this.view = {
        colStart: 0,
        colEnd: this.nDispCols,
        rowStart: 0,
        rowEnd: this.nDispRows
      }
    }

    if (state.gradient && typeof state.gradient === "object") {
      const points = Array.isArray(state.gradient.controlPoints) ? state.gradient.controlPoints : null
      if (points && points.length) {
        this.customGradientControlPoints = points.map((p) => ({
          position: Number(p.position),
          color: Number(p.color)
        }))
        this.gradientControlPoints = this.customGradientControlPoints
      }
      this.customColorRange = state.gradient.customColorRange || null
      this.expressionCustomColorRange = this.customColorRange
        ? { min: Number(this.customColorRange.min), max: Number(this.customColorRange.max) }
        : null
      this.gradientScale = state.gradient.gradientScale || "normal"
      this.nanColor = parseNanColor(state.gradient.nanColor)
      if (this.customColorRange?.min != null) this.gradientMinValue = this.customColorRange.min
      if (this.customColorRange?.max != null) this.gradientMaxValue = this.customColorRange.max
      this.editingGradientTarget = { type: "expression" }
      this.currentMetadataId = "heatmap_expression"
      this.gradientManager.saveGradientForMetadata(this.currentMetadataId)
      this.applyActiveColormap()
    }

    this.applySelectionCheckpointState(state.selection)

    if (state.bottomRightPanel && typeof state.bottomRightPanel === "object") {
      await this.restoreBottomRightPanelState(state)
    } else {
      this.setSelectionTab(state.selection?.activeTab === "gene-sets" ? "gene-sets" : "cells")
    }

    this.handleResize()
  }

  applySelectionCheckpointState(selection) {
    const sel = selection && typeof selection === "object" ? selection : null

    this.geneListHistory = []
    this.geneListItems = Array.isArray(sel?.geneListItems)
      ? sel.geneListItems
        .map((item) => {
          const symbol = this.resolveGeneSymbol(item?.symbol)
          if (!symbol) return null
          return {
            symbol,
            checked: item.checked !== false,
            expanded: !!item.expanded
          }
        })
        .filter(Boolean)
      : []

    this.applyGeneListHighlightState()
    this.renderGeneSearchList()
    this.updateGeneListHistoryControls()

    const nCols = Number.isInteger(this.nOrigCols) ? this.nOrigCols : 0
    this.selectedOrigCols = new Set(
      (Array.isArray(sel?.selectedOrigCols) ? sel.selectedOrigCols : [])
        .map(Number)
        .filter((n) => Number.isInteger(n) && n >= 0 && n < nCols)
    )
    this.selectedCells = new Set(
      (Array.isArray(sel?.selectedCells) ? sel.selectedCells : [])
        .map(Number)
        .filter((n) => Number.isInteger(n) && n >= 0)
    )

    this.updateSelectionPanels()
    this.refreshExpandedGeneHistograms()
    if (typeof this.drawOverlay === "function") this.drawOverlay()
  }

  async restoreTrack(spec, axis) {
    if (!spec || spec.id == null) return
    try {
      if (spec.source === "gene_set_membership" || String(spec.id).startsWith("gene_set_membership:")) {
        const itemId = spec.geneSetItemId || String(spec.id).replace(/^gene_set_membership:/, "")
        await this.addGeneSetMembershipTrack(itemId, {
          thickness: spec.thickness,
          showLegend: Object.prototype.hasOwnProperty.call(spec, "showLegend") ? !!spec.showLegend : true,
          name: spec.name ? String(spec.name).replace(/^Gene set:\s*/i, "") : itemId,
          persist: false
        })
        return
      }
      const track = await this.fetchTrack(spec.id, axis)
      const options = {
        thickness: spec.thickness,
        gradient: spec.gradient,
        type: spec.type,
        displayMode: spec.displayMode
      }
      if (Object.prototype.hasOwnProperty.call(spec, "showLegend")) {
        options.showLegend = !!spec.showLegend
      }
      const prepared = this.prepareTrack(track, options)
      const list = axis === "column" ? this.colTracks : this.rowTracks
      list.push(prepared)
      if (prepared.type === "numerical") {
        this.metadataGradients.set(this.trackGradientMetadataId(prepared), {
          gradientControlPoints: JSON.parse(JSON.stringify(prepared.gradientControlPoints || this.defaultNumericalTrackControlPoints())),
          customGradientControlPoints: prepared.customGradientControlPoints
            ? JSON.parse(JSON.stringify(prepared.customGradientControlPoints))
            : null,
          gradientScale: prepared.gradientScale === "log" ? "log" : "normal",
          nanColor: nanColorToHex(prepared.nanColor)
        })
      }
    } catch (e) {
      console.warn("[heatmap] failed to restore track", spec.id, e)
    }
  }

  async openCheckpointComments(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    if (!this.hasCheckpointCommentsOverlayTarget) return
    await this.fetchCheckpointHistory()
    this.populateCheckpointCommentSelect()
    const focusId = this.checkpointCommentsFocusId || this.lastLoadedCheckpointId
    if (this.hasCheckpointCommentSelectTarget && focusId) {
      this.checkpointCommentSelectTarget.value = String(focusId)
    }
    this.renderCheckpointComments()
    this.checkpointCommentsOverlayTarget.style.display = "flex"
  }

  closeCheckpointComments() {
    if (!this.hasCheckpointCommentsOverlayTarget) return
    this.editingCheckpointCommentId = null
    this.checkpointCommentsOverlayTarget.style.display = "none"
  }

  checkpointCommentsBackdropClick(event) {
    if (event.target === this.checkpointCommentsOverlayTarget) this.closeCheckpointComments()
  }

  populateCheckpointCommentSelect() {
    if (!this.hasCheckpointCommentSelectTarget) return
    const select = this.checkpointCommentSelectTarget
    const history = this.checkpointHistory || []
    select.innerHTML = ""
    if (!history.length) {
      const opt = document.createElement("option")
      opt.value = ""
      opt.textContent = "No checkpoints yet"
      select.appendChild(opt)
      return
    }
    history.forEach((checkpoint) => {
      const opt = document.createElement("option")
      opt.value = String(checkpoint.id)
      const count = Number(checkpoint.comments_count || 0)
      opt.textContent = `${checkpoint.title || "Untitled"} (${count})`
      select.appendChild(opt)
    })
  }

  checkpointCommentTargetChanged() {
    this.editingCheckpointCommentId = null
    this.renderCheckpointComments()
  }

  selectedCommentCheckpointId() {
    if (this.hasCheckpointCommentSelectTarget && this.checkpointCommentSelectTarget.value) {
      return this.checkpointCommentSelectTarget.value
    }
    return this.lastLoadedCheckpointId
  }

  renderCheckpointComments() {
    if (!this.hasCheckpointCommentsListTarget) return
    const checkpointId = this.selectedCommentCheckpointId()
    const checkpoint = this.checkpointForId(checkpointId)
    if (this.hasCheckpointCommentsTitleTarget) {
      this.checkpointCommentsTitleTarget.textContent = checkpoint
        ? `Comments on ${checkpoint.title || "checkpoint"}`
        : "Comments"
    }
    if (!checkpoint) {
      this.editingCheckpointCommentId = null
      this.checkpointCommentsListTarget.innerHTML = `<div style="padding:12px;color:#6b7280;font-size:13px;">Select or load a checkpoint to view comments.</div>`
      return
    }
    const comments = Array.isArray(checkpoint.comments) ? checkpoint.comments : []
    if (!comments.length) {
      this.editingCheckpointCommentId = null
      this.checkpointCommentsListTarget.innerHTML = `<div style="padding:12px;color:#6b7280;font-size:13px;">No comments yet.</div>`
      return
    }
    const editingId = this.editingCheckpointCommentId != null ? String(this.editingCheckpointCommentId) : null
    this.checkpointCommentsListTarget.innerHTML = comments.map((comment) => {
      const authoredAt = comment.created_at ? new Date(comment.created_at).toLocaleString() : ""
      const canManage = comment.user_can_manage === true && this.canAnalyzeValue
      const commentId = this.escape(comment.id || "")
      const isEdited = this.checkpointCommentIsEdited(comment)
      const isEditing = editingId != null && String(comment.id) === editingId
      if (isEditing) {
        return `<div style="padding:10px 16px;border-bottom:1px solid #f3f4f6;" data-checkpoint-comment-id="${commentId}">
          <div style="font-size:12px;font-weight:600;color:#111827;">${this.escape(comment.user_name || "User")}</div>
          <div style="font-size:11px;color:#6b7280;margin:2px 0 8px;">${this.escape(authoredAt)}${isEdited ? ' <span style="font-style:italic;">Edited</span>' : ""}</div>
          <textarea data-checkpoint-comment-edit-input="${commentId}"
                    rows="4"
                    style="width:100%;border:1px solid #d1d5db;border-radius:6px;padding:8px;font-size:13px;line-height:1.45;resize:vertical;box-sizing:border-box;">${this.escape(comment.body || "")}</textarea>
          <div style="display:flex;justify-content:flex-end;gap:6px;margin-top:8px;">
            <button type="button" class="inline-flex items-center px-2 py-1 bg-white hover:bg-gray-100 text-gray-700 rounded border border-gray-300 text-xs"
              data-action="heatmap#cancelCheckpointCommentEdit">Cancel</button>
            <button type="button" class="inline-flex items-center px-2 py-1 bg-blue-600 hover:bg-blue-700 text-white rounded border border-blue-600 text-xs"
              data-action="heatmap#saveCheckpointCommentEdit" data-heatmap-id-param="${commentId}">Save</button>
          </div>
        </div>`
      }
      return `<div style="padding:10px 16px;border-bottom:1px solid #f3f4f6;" data-checkpoint-comment-id="${commentId}">
        <div style="display:flex;justify-content:space-between;gap:8px;align-items:flex-start;">
          <div style="min-width:0;">
            <div style="font-size:12px;font-weight:600;color:#111827;">${this.escape(comment.user_name || "User")}</div>
            <div style="font-size:11px;color:#6b7280;margin-bottom:4px;">${this.escape(authoredAt)}${isEdited ? ' <span style="font-style:italic;">Edited</span>' : ""}</div>
            <div style="font-size:13px;color:#1f2937;white-space:pre-wrap;">${this.escape(comment.body || "")}</div>
          </div>
          ${canManage ? `<div style="display:flex;gap:4px;flex-shrink:0;">
            <button type="button" class="inline-flex items-center px-2 py-1 bg-white hover:bg-gray-100 text-gray-700 rounded border border-gray-300 text-xs"
              data-action="heatmap#editCheckpointComment" data-heatmap-id-param="${commentId}">Edit</button>
            <button type="button" class="inline-flex items-center px-2 py-1 bg-white hover:bg-red-50 text-red-700 rounded border border-red-200 text-xs"
              data-action="heatmap#deleteCheckpointComment" data-heatmap-id-param="${commentId}">Delete</button>
          </div>` : ""}
        </div>
      </div>`
    }).join("")

    if (editingId) {
      const textarea = this.checkpointCommentsListTarget.querySelector(`textarea[data-checkpoint-comment-edit-input="${editingId}"]`)
      if (textarea) {
        textarea.focus()
        const length = textarea.value.length
        textarea.setSelectionRange(length, length)
      }
    }
  }

  checkpointCommentIsEdited(comment) {
    if (!comment || !comment.updated_at) return false
    if (!comment.created_at) return true
    const updatedAt = new Date(comment.updated_at)
    const createdAt = new Date(comment.created_at)
    if (Number.isNaN(updatedAt.getTime()) || Number.isNaN(createdAt.getTime())) return !!comment.updated_at
    return updatedAt.getTime() > createdAt.getTime()
  }

  async submitCheckpointComment() {
    if (!this.canAnalyzeValue) return
    const checkpointId = this.selectedCommentCheckpointId()
    if (!checkpointId) {
      alert("Select a checkpoint first.")
      return
    }
    const body = (this.hasCheckpointCommentInputTarget ? this.checkpointCommentInputTarget.value : "").trim()
    if (!body) {
      alert("Comment cannot be empty.")
      return
    }
    const response = await fetch(this.checkpointsUrl(checkpointId), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin",
      body: JSON.stringify({
        kind: "heatmap",
        run_id: this.runIdValue,
        checkpoint: { comment_body: body }
      })
    })
    if (!response.ok) {
      const errorPayload = await response.json().catch(() => ({}))
      alert(errorPayload.error || `Failed to add comment (${response.status})`)
      return
    }
    const payload = await response.json()
    this.mergeCheckpointIntoHistory(payload.checkpoint)
    if (this.hasCheckpointCommentInputTarget) this.checkpointCommentInputTarget.value = ""
    this.populateCheckpointCommentSelect()
    if (this.hasCheckpointCommentSelectTarget) this.checkpointCommentSelectTarget.value = String(checkpointId)
    this.renderCheckpointComments()
    this.updateCheckpointCommentsButtonState(payload.checkpoint?.comments_count || 0)
  }

  async editCheckpointComment(event) {
    if (!this.canAnalyzeValue) return
    const commentId = event.params.id
    const checkpointId = this.selectedCommentCheckpointId()
    if (!checkpointId || !commentId) return
    const checkpoint = this.checkpointForId(checkpointId)
    const existing = (checkpoint?.comments || []).find((c) => String(c.id) === String(commentId))
    if (!existing || existing.user_can_manage !== true) return
    this.editingCheckpointCommentId = String(commentId)
    this.renderCheckpointComments()
  }

  cancelCheckpointCommentEdit() {
    this.editingCheckpointCommentId = null
    this.renderCheckpointComments()
  }

  async saveCheckpointCommentEdit(event) {
    if (!this.canAnalyzeValue) return
    const commentId = event.params.id
    const checkpointId = this.selectedCommentCheckpointId()
    if (!checkpointId || !commentId) return
    const textarea = this.checkpointCommentsListTarget?.querySelector(`textarea[data-checkpoint-comment-edit-input="${commentId}"]`)
    if (!textarea) return
    const body = String(textarea.value || "").trim()
    if (!body) {
      alert("Comment cannot be empty.")
      textarea.focus()
      return
    }
    const response = await fetch(this.checkpointsUrl(checkpointId), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin",
      body: JSON.stringify({
        kind: "heatmap",
        run_id: this.runIdValue,
        checkpoint: {
          comment_action: "edit",
          comment_id: commentId,
          comment_body: body
        }
      })
    })
    if (!response.ok) {
      const errorPayload = await response.json().catch(() => ({}))
      alert(errorPayload.error || `Failed to edit comment (${response.status})`)
      return
    }
    const payload = await response.json()
    this.editingCheckpointCommentId = null
    this.mergeCheckpointIntoHistory(payload.checkpoint)
    this.renderCheckpointComments()
  }

  async deleteCheckpointComment(event) {
    if (!this.canAnalyzeValue) return
    const commentId = event.params.id
    const checkpointId = this.selectedCommentCheckpointId()
    if (!checkpointId || !commentId) return
    if (!window.confirm("Delete this comment?")) return
    const response = await fetch(this.checkpointsUrl(checkpointId), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin",
      body: JSON.stringify({
        kind: "heatmap",
        run_id: this.runIdValue,
        checkpoint: {
          comment_action: "delete",
          comment_id: commentId
        }
      })
    })
    if (!response.ok) {
      const errorPayload = await response.json().catch(() => ({}))
      alert(errorPayload.error || `Failed to delete comment (${response.status})`)
      return
    }
    const payload = await response.json()
    this.editingCheckpointCommentId = null
    this.mergeCheckpointIntoHistory(payload.checkpoint)
    this.populateCheckpointCommentSelect()
    if (this.hasCheckpointCommentSelectTarget) this.checkpointCommentSelectTarget.value = String(checkpointId)
    this.renderCheckpointComments()
    this.updateCheckpointCommentsButtonState(payload.checkpoint?.comments_count || 0)
  }
}
