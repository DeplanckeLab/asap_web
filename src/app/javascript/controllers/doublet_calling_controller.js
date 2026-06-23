import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "method", "threshold", "nDoublets", "doubletRate",
    "thresholdField", "nDoubletsField", "doubletRateField",
    "statsPanel", "paramsPanel", "histogramPlot", "scatterPlot", "sortedPlot",
    "spinner", "error"
  ]
  static values = {
    filterUrl: String,
    canFilter: Boolean,
    scores: Array,
    initialThreshold: Number,
    initialMethod: String,
    runId: Number
  }

  connect() {
    this.syncMethodFields()
    this.currentThreshold = this.validThreshold(this.initialThresholdValue)
    this.renderAll(this.currentThreshold, {
      doublet_call: {
        method: this.initialMethodValue || "auto",
        threshold_used: this.currentThreshold
      }
    })
    if (this.canFilterValue) {
      this.applyFilter()
    }
  }

  methodChanged() {
    this.syncMethodFields()
  }

  syncMethodFields() {
    const method = this.methodTarget.value
    this.thresholdFieldTarget.classList.toggle("hidden", method !== "threshold")
    this.nDoubletsFieldTarget.classList.toggle("hidden", method !== "top_n")
    this.doubletRateFieldTarget.classList.toggle("hidden", method !== "top_pct")
  }

  applyFilter() {
    if (!this.canFilterValue) return

    this.syncMethodFields()
    if (this.hasErrorTarget) this.errorTarget.classList.add("hidden")
    if (this.hasSpinnerTarget) this.spinnerTarget.classList.remove("hidden")

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content")
    const formData = new FormData()
    formData.append("filter[method]", this.methodTarget.value)
    formData.append("filter[run_id]", this.runIdValue)
    if (this.methodTarget.value === "threshold") {
      formData.append("filter[threshold]", this.thresholdTarget.value)
    } else if (this.methodTarget.value === "top_n") {
      formData.append("filter[n_doublets]", this.nDoubletsTarget.value)
    } else if (this.methodTarget.value === "top_pct") {
      formData.append("filter[doublet_rate]", this.doubletRateTarget.value)
    }

    fetch(this.filterUrlValue, {
      method: "POST",
      headers: {
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: formData,
      credentials: "same-origin"
    })
      .then((response) => {
        if (!response.ok) {
          return response.json().then((payload) => {
            throw new Error(payload.error || `HTTP ${response.status}`)
          })
        }
        return response.json()
      })
      .then((payload) => {
        this.currentThreshold = this.validThreshold(payload?.doublet_call?.threshold_used)
        this.renderAll(this.currentThreshold, payload)
      })
      .catch((error) => {
        console.error("[DoubletCallingController]", error)
        if (this.hasErrorTarget) {
          this.errorTarget.textContent = error.message || "Doublet calling filter failed."
          this.errorTarget.classList.remove("hidden")
        }
      })
      .finally(() => {
        if (this.hasSpinnerTarget) this.spinnerTarget.classList.add("hidden")
      })
  }

  renderAll(threshold, payload) {
    const block = payload?.doublet_call || {}
    const scores = this.scoresValue || []
    const t = this.validThreshold(threshold)
    let nDoublets = block.n_doublets_called
    let nSinglets = block.n_singlets_called
    let rate = block.doublet_rate

    if (scores.length && Number.isFinite(t)) {
      if (nDoublets === undefined || nDoublets === null) {
        nDoublets = scores.filter((s) => s >= t).length
      }
      if (nSinglets === undefined || nSinglets === null) {
        nSinglets = scores.length - nDoublets
      }
      if (rate === undefined || rate === null) {
        rate = scores.length ? nDoublets / scores.length : null
      }
    }

    this.updateStatsPanel(block, nDoublets, nSinglets, rate, t)
    this.updateCallingParamsPanel(block, payload)
    if (Number.isFinite(t)) {
      this.renderHistogram(t)
      this.renderScatter(t)
      this.renderSortedScores(t)
    }
  }

  updateStatsPanel(block, nDoublets, nSinglets, rate, threshold) {
    if (!this.hasStatsPanelTarget) return

    this.statsPanelTarget.innerHTML = `
      <div class="inline-flex items-center gap-2 px-4 py-2 bg-red-50 border border-red-200 rounded-lg">
        <span class="text-sm font-medium text-red-900">Doublets: <span class="font-bold">${this.formatNum(nDoublets)}</span></span>
      </div>
      <div class="inline-flex items-center gap-2 px-4 py-2 bg-green-50 border border-green-200 rounded-lg">
        <span class="text-sm font-medium text-green-900">Singlets: <span class="font-bold">${this.formatNum(nSinglets)}</span></span>
      </div>
      <div class="inline-flex items-center gap-2 px-4 py-2 bg-gray-50 border border-gray-200 rounded-lg">
        <span class="text-sm font-medium text-gray-900">Doublet rate: <span class="font-bold">${this.formatRate(rate)}</span></span>
      </div>
      <div class="inline-flex items-center gap-2 px-4 py-2 bg-indigo-50 border border-indigo-200 rounded-lg">
        <span class="text-sm font-medium text-indigo-900">Threshold: <span class="font-bold">${this.formatThreshold(threshold)}</span></span>
      </div>
    `
  }

  updateCallingParamsPanel(block, payload) {
    if (!this.hasParamsPanelTarget) return

    const params = payload?.parameters || {}
    const method = block.method || params.method || this.methodTarget?.value || "-"
    const thresholdUsed = block.threshold_used
    const rows = [
      `<div><div class="font-medium text-gray-700">Calling method</div><div class="text-gray-900 mt-0.5">${this.escapeHtml(method)}</div></div>`
    ]

    if (thresholdUsed !== undefined && thresholdUsed !== null && thresholdUsed !== "") {
      rows.push(
        `<div><div class="font-medium text-gray-700">Threshold used</div><div class="text-gray-900 mt-0.5">${this.formatThreshold(thresholdUsed)}</div></div>`
      )
    }
    if (params.threshold !== undefined && params.threshold !== null && params.threshold !== "") {
      rows.push(
        `<div><div class="font-medium text-gray-700">Threshold</div><div class="text-gray-900 mt-0.5">${this.escapeHtml(params.threshold)}</div></div>`
      )
    }
    if (params.n_doublets !== undefined && params.n_doublets !== null && params.n_doublets !== "") {
      rows.push(
        `<div><div class="font-medium text-gray-700">Number of doublets</div><div class="text-gray-900 mt-0.5">${this.formatNum(params.n_doublets)}</div></div>`
      )
    }
    if (params.doublet_rate !== undefined && params.doublet_rate !== null && params.doublet_rate !== "") {
      rows.push(
        `<div><div class="font-medium text-gray-700">Doublet rate</div><div class="text-gray-900 mt-0.5">${this.formatRate(params.doublet_rate)}</div></div>`
      )
    }

    this.paramsPanelTarget.innerHTML = rows.join("")
  }

  escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  splitScores(threshold) {
    const scores = this.scoresValue || []
    const t = Number(threshold)
    const singlets = []
    const doublets = []
    scores.forEach((s) => {
      if (Number.isFinite(t) && s >= t) doublets.push(s)
      else singlets.push(s)
    })
    return { singlets, doublets }
  }

  renderHistogram(threshold) {
    if (!this.hasHistogramPlotTarget || !window.Plotly) return
    const { singlets, doublets } = this.splitScores(threshold)
    if (!singlets.length && !doublets.length) return

    const traces = [
      {
        x: singlets,
        type: "histogram",
        name: "Singlet",
        marker: { color: "#16a34a" },
        opacity: 0.85,
        histnorm: "count"
      },
      {
        x: doublets,
        type: "histogram",
        name: "Doublet",
        marker: { color: "#dc2626" },
        opacity: 0.85,
        histnorm: "count"
      }
    ]

    const layout = {
      title: "Score distribution (singlet vs doublet)",
      xaxis: { title: "Doublet score" },
      yaxis: { title: "Cells" },
      barmode: "stack",
      margin: { t: 40, r: 20, b: 50, l: 50 },
      shapes: this.thresholdLineV(threshold),
      legend: { orientation: "h", y: 1.12 }
    }

    Plotly.react(this.histogramPlotTarget, traces, layout, { responsive: true, displayModeBar: true })
  }

  renderScatter(threshold) {
    if (!this.hasScatterPlotTarget || !window.Plotly) return
    const scores = this.scoresValue || []
    const t = Number(threshold)
    if (!scores.length || !Number.isFinite(t)) return

    const singletX = []
    const singletY = []
    const doubletX = []
    const doubletY = []
    scores.forEach((s, i) => {
      if (s >= t) {
        doubletX.push(i)
        doubletY.push(s)
      } else {
        singletX.push(i)
        singletY.push(s)
      }
    })

    const traces = [
      {
        x: singletX,
        y: singletY,
        mode: "markers",
        type: "scattergl",
        name: "Singlet",
        marker: { color: "#16a34a", size: 4, opacity: 0.6 }
      },
      {
        x: doubletX,
        y: doubletY,
        mode: "markers",
        type: "scattergl",
        name: "Doublet",
        marker: { color: "#dc2626", size: 4, opacity: 0.7 }
      }
    ]

    const layout = {
      title: "Per-cell doublet scores",
      xaxis: { title: "Cell index" },
      yaxis: { title: "Doublet score" },
      margin: { t: 40, r: 20, b: 50, l: 50 },
      shapes: this.thresholdLineH(threshold),
      legend: { orientation: "h", y: 1.12 }
    }

    Plotly.react(this.scatterPlotTarget, traces, layout, { responsive: true, displayModeBar: true })
  }

  renderSortedScores(threshold) {
    if (!this.hasSortedPlotTarget || !window.Plotly) return
    const scores = [...(this.scoresValue || [])].sort((a, b) => a - b)
    const t = Number(threshold)
    if (!scores.length || !Number.isFinite(t)) return

    const xs = scores.map((_, i) => i + 1)
    const colors = scores.map((s) => (s >= t ? "#dc2626" : "#16a34a"))

    const traces = [{
      x: xs,
      y: scores,
      mode: "markers",
      type: "scatter",
      name: "Sorted scores",
      marker: { color: colors, size: 5, opacity: 0.8 },
      showlegend: false
    }]

    const layout = {
      title: "Sorted scores (green = singlet, red = doublet)",
      xaxis: { title: "Rank (low to high score)" },
      yaxis: { title: "Doublet score" },
      margin: { t: 40, r: 20, b: 50, l: 50 },
      shapes: this.thresholdLineH(threshold)
    }

    Plotly.react(this.sortedPlotTarget, traces, layout, { responsive: true, displayModeBar: true })
  }

  thresholdLineV(threshold) {
    const t = Number(threshold)
    if (!Number.isFinite(t)) return []
    return [{
      type: "line",
      x0: t,
      x1: t,
      y0: 0,
      y1: 1,
      yref: "paper",
      line: { color: "#ea580c", width: 2, dash: "dash" }
    }]
  }

  thresholdLineH(threshold) {
    const t = Number(threshold)
    if (!Number.isFinite(t)) return []
    return [{
      type: "line",
      x0: 0,
      x1: 1,
      xref: "paper",
      y0: t,
      y1: t,
      line: { color: "#ea580c", width: 2, dash: "dash" }
    }]
  }

  validThreshold(value) {
    const n = Number(value)
    return Number.isFinite(n) ? n : null
  }

  formatNum(value) {
    if (value === null || value === undefined) return "-"
    const n = Number(value)
    return Number.isFinite(n) ? n.toLocaleString() : "-"
  }

  formatRate(value) {
    if (value === null || value === undefined) return "-"
    const n = Number(value)
    return Number.isFinite(n) ? `${(n * 100).toFixed(2)}%` : "-"
  }

  formatThreshold(value) {
    if (value === null || value === undefined) return "-"
    const n = Number(value)
    return Number.isFinite(n) ? n.toFixed(4) : "-"
  }
}
