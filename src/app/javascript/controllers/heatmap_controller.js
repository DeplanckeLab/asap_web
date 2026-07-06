import { Controller } from "@hotwired/stimulus"
import { ReglHeatmap } from "visualization/regl_heatmap"

// Interactive expression heatmap viewer.
//
// Renders the precomputed genes x columns matrix (WebGL) with a Canvas 2D
// overlay for collapsible row/column dendrograms, categorical/numerical
// annotation tracks, axis labels and a colormap legend. Supports wheel zoom,
// drag pan, reset, and per-branch collapse (which aggregates the matrix).
export default class extends Controller {
  static values = {
    projectKey: String,
    runId: String,
    dataUrl: String
  }

  static targets = [
    "webgl", "overlay", "status", "tooltip",
    "colTrackSelect", "rowTrackSelect", "activeTracks", "legendPanel"
  ]

  connect() {
    this.dpr = window.devicePixelRatio || 1
    this.showRowTree = true
    this.showColTree = true
    this.showLabels = true
    this.rowCollapsed = new Set()
    this.colCollapsed = new Set()
    this.dragging = false
    this.colTracks = []
    this.rowTracks = []
    this.loomFile = null
    this.metadataCatalog = { column_metadata: [], row_metadata: [] }
    this.legendMaxCategories = 12

    this.layout = {
      colTreeH: 90,
      rowTreeW: 120,
      trackW: 16,
      trackH: 16,
      trackGap: 3,
      rowLabelW: 150,
      colLabelH: 90,
      legendW: 70,
      pad: 8
    }

    this.boundResize = this.handleResize.bind(this)
    window.addEventListener("resize", this.boundResize)

    this.loadData()
  }

  disconnect() {
    window.removeEventListener("resize", this.boundResize)
    if (this.renderer) {
      this.renderer.destroy()
      this.renderer = null
    }
  }

  setStatus(message) {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = message || ""
      this.statusTarget.style.display = message ? "block" : "none"
    }
  }

  async loadData() {
    this.setStatus("Loading heatmap...")
    try {
      const metaRes = await fetch(this.dataUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!metaRes.ok) {
        const body = await metaRes.json().catch(() => ({}))
        this.setStatus(body.error || "Heatmap results are not available yet.")
        return
      }
      this.meta = await metaRes.json()

      if ((this.meta.warnings || []).length) {
        console.warn("[heatmap] warnings:", this.meta.warnings)
      }

      const matrixUrl = this.meta.matrix_url
      if (!matrixUrl) {
        this.setStatus("Heatmap matrix is missing.")
        return
      }
      const matRes = await fetch(matrixUrl, { credentials: "same-origin" })
      if (!matRes.ok) {
        this.setStatus("Failed to load heatmap matrix.")
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
        this.setStatus("Heatmap matrix size does not match metadata.")
        return
      }

      this.rowTree = this.prepareTree(this.meta.row_tree, this.nOrigRows)
      this.colTree = this.prepareTree(this.meta.col_tree, this.nOrigCols)
      this.loomFile = this.meta.loom_file || null

      this.setStatus("")
      this.setupRenderer()
      this.rebuildDisplay()
      this.resetView(false)
      this.bindEvents()
      await this.loadMetadataCatalog()
      this.handleResize()
    } catch (e) {
      console.error("[heatmap] load failed", e)
      this.setStatus("Failed to load heatmap: " + e.message)
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
    this.renderer.setColormap(this.diverging)
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
    this.fillTrackSelect(this.colTrackSelectTarget, this.metadataCatalog.column_metadata || [], this.colTracks)
    this.fillTrackSelect(this.rowTrackSelectTarget, this.metadataCatalog.row_metadata || [], this.rowTracks)
  }

  fillTrackSelect(selectEl, options, activeTracks) {
    if (!selectEl) return
    const activeIds = new Set(activeTracks.map((t) => String(t.id)))
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
      selectEl.appendChild(option)
    })
  }

  async addColTrack() {
    const id = this.colTrackSelectTarget?.value
    if (!id) return
    await this.addTrack(id, "column")
  }

  async addRowTrack() {
    const id = this.rowTrackSelectTarget?.value
    if (!id) return
    await this.addTrack(id, "row")
  }

  async addTrack(metadataId, axis) {
    const list = axis === "column" ? this.colTracks : this.rowTracks
    if (list.some((t) => String(t.id) === String(metadataId))) return

    const loading = { id: metadataId, name: "Loading...", type: "categorical", values: [], loading: true }
    list.push(loading)
    this.renderActiveTracksList()
    this.handleResize()

    try {
      const track = await this.fetchTrack(metadataId, axis)
      const idx = list.findIndex((t) => String(t.id) === String(metadataId) && t.loading)
      if (idx >= 0) list[idx] = this.prepareTrack(track)
      else list.push(this.prepareTrack(track))
    } catch (e) {
      const idx = list.findIndex((t) => String(t.id) === String(metadataId) && t.loading)
      if (idx >= 0) list.splice(idx, 1)
      console.error("[heatmap] add track failed", e)
    }
    this.populateTrackSelects()
    this.renderActiveTracksList()
    this.renderTrackLegends()
    this.handleResize()
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
    this.renderActiveTracksList()
    this.renderTrackLegends()
    this.handleResize()
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

  prepareTrack(track) {
    const prepared = {
      id: track.id,
      name: track.name,
      type: track.type,
      values: Array.isArray(track.values) ? track.values : [],
      min: track.min,
      max: track.max,
      categories: Array.isArray(track.categories) ? track.categories : [],
      showLegend: track.show_legend !== false && track.type === "categorical" &&
        Array.isArray(track.categories) && track.categories.length <= this.legendMaxCategories,
      _catIndex: {}
    }
    if (prepared.type === "categorical") {
      prepared.categories.forEach((cat, i) => { prepared._catIndex[cat] = i })
    }
    return prepared
  }

  renderActiveTracksList() {
    if (!this.hasActiveTracksTarget) return
    const chips = []
    this.colTracks.filter((t) => !t.loading).forEach((t) => {
      chips.push(`<span class="badge bg-light text-dark border" style="font-weight:normal;">
        Col: ${this.escape(t.name)}
        <button type="button" class="btn-close btn-close-sm ms-1" style="font-size:0.55rem;"
          data-action="heatmap#removeColTrack" data-heatmap-id-param="${t.id}" aria-label="Remove"></button>
      </span>`)
    })
    this.rowTracks.filter((t) => !t.loading).forEach((t) => {
      chips.push(`<span class="badge bg-light text-dark border" style="font-weight:normal;">
        Row: ${this.escape(t.name)}
        <button type="button" class="btn-close btn-close-sm ms-1" style="font-size:0.55rem;"
          data-action="heatmap#removeRowTrack" data-heatmap-id-param="${t.id}" aria-label="Remove"></button>
      </span>`)
    })
    this.activeTracksTarget.innerHTML = chips.join("")
  }

  renderTrackLegends() {
    if (!this.hasLegendPanelTarget) return
    const blocks = []
    const allTracks = [
      ...this.colTracks.map((t) => ({ ...t, axis: "column" })),
      ...this.rowTracks.map((t) => ({ ...t, axis: "row" }))
    ].filter((t) => !t.loading)

    allTracks.forEach((track) => {
      if (track.type === "numerical") {
        blocks.push(`<div class="heatmap-track-legend" style="font-size:11px;">
          <div class="text-gray-600 mb-1">${this.escape(track.axis === "column" ? "Col" : "Row")}: ${this.escape(track.name)}</div>
          <div style="display:flex;align-items:center;gap:4px;">
            <span>${Number(track.min).toPrecision(3)}</span>
            <div style="width:48px;height:10px;background:linear-gradient(to right,#fff,#00f);border:1px solid #cbd5e1;"></div>
            <span>${Number(track.max).toPrecision(3)}</span>
          </div>
        </div>`)
        return
      }
      if (!track.showLegend) {
        blocks.push(`<div class="heatmap-track-legend text-gray-500" style="font-size:11px;">
          ${this.escape(track.axis === "column" ? "Col" : "Row")}: ${this.escape(track.name)}
          <span class="text-gray-400"> (hover for values)</span>
        </div>`)
        return
      }
      const items = track.categories.map((cat) => {
        const color = this.categoricalPalette(track._catIndex[cat] ?? 0)
        return `<span style="display:inline-flex;align-items:center;gap:3px;margin-right:8px;">
          <span style="width:10px;height:10px;background:${color};border:1px solid #94a3b8;display:inline-block;"></span>
          <span>${this.escape(cat)}</span>
        </span>`
      }).join("")
      blocks.push(`<div class="heatmap-track-legend" style="font-size:11px;">
        <div class="text-gray-600 mb-1">${this.escape(track.axis === "column" ? "Col" : "Row")}: ${this.escape(track.name)}</div>
        <div>${items}</div>
      </div>`)
    })
    this.legendPanelTarget.innerHTML = blocks.join("")
    this.legendPanelTarget.style.display = blocks.length ? "flex" : "none"
  }

  // Build display groups (contiguous leaf ranges) honoring collapsed nodes,
  // then aggregate the base matrix into the displayed matrix.
  rebuildDisplay() {
    this.colGroups = this.buildGroups(this.colTree, this.nOrigCols, this.colCollapsed)
    this.rowGroups = this.buildGroups(this.rowTree, this.nOrigRows, this.rowCollapsed)

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
    this.renderer.setMatrix(finalMat, nDispRows, nDispCols, this.vmin, this.vmax)
  }

  buildGroups(tree, nLeaves, collapsed) {
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
      if (collapsed.has(node.id)) {
        groups.push([node.minLeaf, node.maxLeaf])
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
    this.rowCollapsed.clear()
    this.colCollapsed.clear()
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
    this.resetView(true)
    this.handleResize()
  }

  toggleRowTree() { this.showRowTree = !this.showRowTree; this.handleResize() }
  toggleColTree() { this.showColTree = !this.showColTree; this.handleResize() }
  toggleLabels() { this.showLabels = !this.showLabels; this.render() }

  handleResize() {
    if (!this.renderer) return
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
    gl.width = Math.max(1, Math.round(this.mw * this.dpr))
    gl.height = Math.max(1, Math.round(this.mh * this.dpr))

    const ov = this.overlayTarget
    ov.style.position = "absolute"
    ov.style.left = "0px"
    ov.style.top = "0px"
    ov.style.width = w + "px"
    ov.style.height = h + "px"
    ov.width = Math.max(1, Math.round(w * this.dpr))
    ov.height = Math.max(1, Math.round(h * this.dpr))

    this.render()
  }

  computeLayout() {
    const L = this.layout
    const nColTracks = this.colTracks.filter((t) => !t.loading).length
    const nRowTracks = this.rowTracks.filter((t) => !t.loading).length

    const colTreeH = this.showColTree && this.colTree ? L.colTreeH : 0
    const rowTreeW = this.showRowTree && this.rowTree ? L.rowTreeW : 0

    this.leftTracksW = nRowTracks * (L.trackW + L.trackGap)
    this.topTracksH = nColTracks * (L.trackH + L.trackGap)

    this.mx = L.pad + rowTreeW + this.leftTracksW
    this.my = L.pad + colTreeH + this.topTracksH
    this.colTreeH = colTreeH
    this.rowTreeW = rowTreeW

    this.mw = Math.max(20, this.containerW - this.mx - L.rowLabelW - L.legendW - L.pad)
    this.mh = Math.max(20, this.containerH - this.my - L.colLabelH - L.pad)
  }

  bindEvents() {
    const ov = this.overlayTarget
    ov.addEventListener("wheel", (e) => this.onWheel(e), { passive: false })
    ov.addEventListener("mousedown", (e) => this.onMouseDown(e))
    window.addEventListener("mousemove", (e) => this.onMouseMove(e))
    window.addEventListener("mouseup", () => this.onMouseUp())
    ov.addEventListener("click", (e) => this.onClick(e))
    ov.addEventListener("mouseleave", () => this.hideTooltip())
  }

  localPoint(e) {
    const rect = this.overlayTarget.getBoundingClientRect()
    return { x: e.clientX - rect.left, y: e.clientY - rect.top }
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

  onWheel(e) {
    e.preventDefault()
    const p = this.localPoint(e)
    if (!this.inMatrix(p)) return
    const factor = e.deltaY < 0 ? 0.85 : 1.176
    const v = this.view
    const cx = this.colForX(p.x)
    const cy = this.rowForY(p.y)

    let colSpan = (v.colEnd - v.colStart) * factor
    let rowSpan = (v.rowEnd - v.rowStart) * factor
    colSpan = Math.min(this.nDispCols, Math.max(1, colSpan))
    rowSpan = Math.min(this.nDispRows, Math.max(1, rowSpan))

    const colFrac = (cx - v.colStart) / (v.colEnd - v.colStart)
    const rowFrac = (cy - v.rowStart) / (v.rowEnd - v.rowStart)

    v.colStart = cx - colFrac * colSpan
    v.colEnd = v.colStart + colSpan
    v.rowStart = cy - rowFrac * rowSpan
    v.rowEnd = v.rowStart + rowSpan
    this.clampView()
    this.render()
  }

  onMouseDown(e) {
    const p = this.localPoint(e)
    if (!this.inMatrix(p)) return
    this.dragging = true
    this.dragStart = { x: p.x, y: p.y, view: { ...this.view } }
  }

  onMouseMove(e) {
    const p = this.localPoint(e)
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

  onMouseUp() {
    this.dragging = false
    this.dragStart = null
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

  // Click on a dendrogram internal node toggles collapse of that subtree.
  onClick(e) {
    const p = this.localPoint(e)
    let changed = false
    if (this.showColTree && this.colTree && p.y >= this.layout.pad && p.y <= this.layout.pad + this.colTreeH) {
      const node = this.hitTestTree(this.colTree, p, "col")
      if (node) { this.toggleCollapse(this.colCollapsed, node.id); changed = true }
    } else if (this.showRowTree && this.rowTree && p.x >= this.layout.pad && p.x <= this.layout.pad + this.rowTreeW) {
      const node = this.hitTestTree(this.rowTree, p, "row")
      if (node) { this.toggleCollapse(this.rowCollapsed, node.id); changed = true }
    }
    if (changed) {
      this.rebuildDisplay()
      this.clampView()
      this.render()
    }
  }

  toggleCollapse(set, id) {
    if (set.has(id)) set.delete(id)
    else set.add(id)
  }

  hitTestTree(tree, p, axis) {
    let best = null
    let bestDist = 14
    const maxH = tree.maxHeight
    const visit = (node) => {
      if (node.leaf) return
      if (axis === "col" && this.colCollapsed.has(node.id)) { /* still hittable to expand */ }
      const centerDisp = this.nodeDisplayCenter(node, axis)
      let nx, ny
      if (axis === "col") {
        nx = this.xForCol(centerDisp)
        ny = this.layout.pad + this.colTreeH * (1 - node.height / maxH)
      } else {
        ny = this.yForRow(centerDisp)
        nx = this.layout.pad + this.rowTreeW * (1 - node.height / maxH)
      }
      const d = Math.hypot(nx - p.x, ny - p.y)
      if (d < bestDist) { bestDist = d; best = node }
      const collapsed = (axis === "col" ? this.colCollapsed : this.rowCollapsed).has(node.id)
      if (!collapsed) node.children.forEach(visit)
    }
    visit(tree.root)
    return best
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

    if (this.showColTree && this.colTree) this.drawDendrogram(ctx, this.colTree, "col")
    if (this.showRowTree && this.rowTree) this.drawDendrogram(ctx, this.rowTree, "row")

    this.drawTracks(ctx)
    if (this.showLabels) this.drawLabels(ctx)
    this.drawLegend(ctx)
  }

  drawDendrogram(ctx, tree, axis) {
    const maxH = tree.maxHeight
    ctx.strokeStyle = "#475569"
    ctx.fillStyle = "#94a3b8"
    ctx.lineWidth = 1

    const collapsedSet = axis === "col" ? this.colCollapsed : this.rowCollapsed
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
      if (collapsedSet.has(node.id)) {
        const center = this.nodeDisplayCenter(node, axis)
        const main = axis === "col" ? this.xForCol(center) : this.yForRow(center)
        const p = posOf(node)
        // draw a collapsed wedge
        const halfW = 5
        ctx.beginPath()
        if (axis === "col") {
          ctx.moveTo(main, p.depth)
          ctx.lineTo(main - halfW, leafDepth)
          ctx.lineTo(main + halfW, leafDepth)
        } else {
          ctx.moveTo(p.depth, main)
          ctx.lineTo(leafDepth, main - halfW)
          ctx.lineTo(leafDepth, main + halfW)
        }
        ctx.closePath()
        ctx.fill()
        return { main, depth: p.depth }
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
      return "#e5e7eb"
    }
    if (track.type === "numerical") {
      const min = track.min
      const max = track.max
      const t = max > min ? (value - min) / (max - min) : 0.5
      const c = Math.round(255 * (1 - Math.max(0, Math.min(1, t))))
      return `rgb(${c},${c},255)`
    }
    if (!track._catIndex) {
      track._catIndex = {}
      let i = 0
      ;(track.categories || []).forEach((cat) => { track._catIndex[cat] = i++ })
    }
    const key = value === null || value === undefined ? null : String(value)
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

  drawTracks(ctx) {
    const L = this.layout
    const colTracks = this.colTracks.filter((t) => !t.loading)
    const rowTracks = this.rowTracks.filter((t) => !t.loading)

    ctx.save()
    ctx.beginPath(); ctx.rect(this.mx, L.pad, this.mw, this.containerH); ctx.clip()
    colTracks.forEach((track, ti) => {
      const y = L.pad + this.colTreeH + ti * (L.trackH + L.trackGap)
      for (let d = 0; d < this.nDispCols; d++) {
        const x0 = this.xForCol(d)
        const x1 = this.xForCol(d + 1)
        if (x1 < this.mx || x0 > this.mx + this.mw) continue
        ctx.fillStyle = this.trackColor(track, this.aggregateTrack(track, this.colGroups[d]))
        ctx.fillRect(x0, y, Math.max(1, x1 - x0), L.trackH)
      }
      ctx.fillStyle = "#334155"
      ctx.font = "10px sans-serif"
      ctx.textAlign = "right"
      ctx.textBaseline = "middle"
      ctx.fillText(this.truncate(track.name, 18), this.mx - 4, y + L.trackH / 2)
    })
    ctx.restore()

    ctx.save()
    ctx.beginPath(); ctx.rect(L.pad, this.my, this.containerW, this.mh); ctx.clip()
    rowTracks.forEach((track, ti) => {
      const x = this.mx - this.leftTracksW + ti * (L.trackW + L.trackGap)
      for (let d = 0; d < this.nDispRows; d++) {
        const y0 = this.yForRow(d)
        const y1 = this.yForRow(d + 1)
        if (y1 < this.my || y0 > this.my + this.mh) continue
        ctx.fillStyle = this.trackColor(track, this.aggregateTrack(track, this.rowGroups[d]))
        ctx.fillRect(x, y0, L.trackW, Math.max(1, y1 - y0))
      }
      ctx.fillStyle = "#334155"
      ctx.font = "10px sans-serif"
      ctx.textAlign = "center"
      ctx.textBaseline = "bottom"
      ctx.save()
      ctx.translate(x + L.trackW / 2, this.my - 3)
      ctx.rotate(-Math.PI / 2)
      ctx.fillText(this.truncate(track.name, 14), 0, 0)
      ctx.restore()
    })
    ctx.restore()
  }

  hitTestTracks(p) {
    const L = this.layout
    const colTracks = this.colTracks.filter((t) => !t.loading)
    const rowTracks = this.rowTracks.filter((t) => !t.loading)

    for (let ti = 0; ti < colTracks.length; ti++) {
      const y0 = L.pad + this.colTreeH + ti * (L.trackH + L.trackGap)
      const y1 = y0 + L.trackH
      if (p.y < y0 || p.y > y1 || p.x < this.mx || p.x > this.mx + this.mw) continue
      const d = Math.floor(this.colForX(p.x))
      if (d < 0 || d >= this.nDispCols) continue
      return { axis: "column", track: colTracks[ti], displayIndex: d }
    }

    for (let ti = 0; ti < rowTracks.length; ti++) {
      const x0 = this.mx - this.leftTracksW + ti * (L.trackW + L.trackGap)
      const x1 = x0 + L.trackW
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
    const html = `<strong>${this.escape(hit.track.name)}</strong><br>${this.escape(label)}<br>${this.escape(displayValue)}`
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
        ctx.fillText(this.truncate(this.displayRowLabel(d), 22), this.mx + this.mw + 5, y)
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
    const x = this.containerW - this.layout.legendW + 12
    const y = this.layout.pad + 4
    const h = 120
    const w = 14
    const grad = ctx.createLinearGradient(0, y, 0, y + h)
    if (this.diverging) {
      grad.addColorStop(0, "#b5171a")
      grad.addColorStop(0.5, "#f7f7f7")
      grad.addColorStop(1, "#3b4dbf")
    } else {
      grad.addColorStop(0, "#fce728")
      grad.addColorStop(0.5, "#21918c")
      grad.addColorStop(1, "#450a54")
    }
    ctx.fillStyle = grad
    ctx.fillRect(x, y, w, h)
    ctx.strokeStyle = "#94a3b8"
    ctx.strokeRect(x, y, w, h)
    ctx.fillStyle = "#334155"
    ctx.font = "9px sans-serif"
    ctx.textAlign = "left"
    ctx.textBaseline = "middle"
    ctx.fillText(this.vmax.toFixed(1), x + w + 3, y + 4)
    ctx.fillText(((this.vmax + this.vmin) / 2).toFixed(1), x + w + 3, y + h / 2)
    ctx.fillText(this.vmin.toFixed(1), x + w + 3, y + h - 4)
  }

  updateTooltip(p, e) {
    const c = Math.floor(this.colForX(p.x))
    const r = Math.floor(this.rowForY(p.y))
    if (c < 0 || c >= this.nDispCols || r < 0 || r >= this.nDispRows) { this.hideTooltip(); return }
    const gene = this.displayRowLabel(r)
    const col = this.displayColLabel(c)
    const html = `<strong>${this.escape(gene)}</strong><br>${this.escape(col)}`
    if (this.hasTooltipTarget) {
      this.tooltipTarget.innerHTML = html
      this.tooltipTarget.style.display = "block"
      const rect = this.element.querySelector(".heatmap-canvas-area").getBoundingClientRect()
      this.tooltipTarget.style.left = (p.x + 12) + "px"
      this.tooltipTarget.style.top = (p.y + 12) + "px"
    }
  }

  hideTooltip() {
    if (this.hasTooltipTarget) this.tooltipTarget.style.display = "none"
  }

  truncate(s, n) {
    s = String(s == null ? "" : s)
    return s.length > n ? s.slice(0, n - 1) + "\u2026" : s
  }

  escape(s) {
    const div = document.createElement("div")
    div.textContent = String(s == null ? "" : s)
    return div.innerHTML
  }
}
