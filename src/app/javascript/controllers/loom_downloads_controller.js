import { Controller } from "@hotwired/stimulus"

// Shared LOOM / H5AD / DNA accessibility downloads modal.
// Open triggers may live outside this element; use [data-loom-downloads-open].
export default class extends Controller {
  static targets = ["overlay", "panel", "body", "closeButton"]
  static values = {
    jsonUrl: String,
    exportUrl: String,
    statusIcons: Array
  }

  connect() {
    this.pollTimer = null
    this.latestItems = []
    this.statusIconsByKey = {}
    ;(this.statusIconsValue || []).forEach((entry) => {
      if (entry && entry.key) this.statusIconsByKey[entry.key] = entry
    })

    this.documentOpenHandler = this.handleDocumentOpen.bind(this)
    this.keydownHandler = this.handleKeydown.bind(this)
    this.bodyClickHandler = this.handleBodyClick.bind(this)

    document.addEventListener("click", this.documentOpenHandler)
    document.addEventListener("keydown", this.keydownHandler)
    if (this.hasBodyTarget) {
      this.bodyTarget.addEventListener("click", this.bodyClickHandler)
    }
  }

  disconnect() {
    this.stopPolling()
    document.removeEventListener("click", this.documentOpenHandler)
    document.removeEventListener("keydown", this.keydownHandler)
    if (this.hasBodyTarget) {
      this.bodyTarget.removeEventListener("click", this.bodyClickHandler)
    }
  }

  handleDocumentOpen(event) {
    const trigger = event.target.closest("[data-loom-downloads-open]")
    if (!trigger) return
    if (trigger.getAttribute("aria-disabled") === "true" || trigger.disabled) return
    event.preventDefault()
    event.stopPropagation()
    this.closeSurroundingMenus()
    this.loadAndShow()
  }

  closeSurroundingMenus() {
    document.querySelectorAll('[data-controller~="nav-dropdown"]').forEach((dropdown) => {
      dropdown.dispatchEvent(new CustomEvent("nav-dropdown:close", { bubbles: false }))
    })
    document.querySelectorAll('[data-mobile-menu-target="menu"]').forEach((menu) => {
      menu.classList.add("hidden")
    })
    document.querySelectorAll('[data-mobile-menu-target="toggle"]').forEach((toggle) => {
      toggle.setAttribute("aria-expanded", "false")
    })
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.isOpen()) this.close()
  }

  open() {
    if (!this.hasOverlayTarget) return
    this.overlayTarget.classList.remove("hidden")
  }

  close() {
    this.stopPolling()
    if (!this.hasOverlayTarget) return
    this.overlayTarget.classList.add("hidden")
  }

  closeFromButton(event) {
    event.stopPropagation()
    this.close()
  }

  stopOverlayClick(event) {
    event.stopPropagation()
  }

  isOpen() {
    return this.hasOverlayTarget && !this.overlayTarget.classList.contains("hidden")
  }

  escapeHtml(value) {
    return String(value == null ? "" : value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }

  stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  statusIconHtml(h5adStatus, statusId) {
    let key = null
    if (statusId === 1 || statusId === 6 || h5adStatus === "pending") key = "pending"
    else if (statusId === 2 || h5adStatus === "running") key = "running"
    else if (statusId === 3 || h5adStatus === "ready") key = "success"
    else if (statusId === 4 || statusId === 5 || h5adStatus === "failed") key = "failed"
    else if (h5adStatus === "stale") key = "waiting"

    const cfg = key ? this.statusIconsByKey[key] : null
    if (!cfg) {
      return '<i class="fas fa-circle text-gray-300" style="font-size: 12px;" aria-hidden="true"></i>'
    }
    const spin = cfg.icon_spin ? ` ${cfg.icon_spin}` : ""
    const color = cfg.active_color || "text-gray-500"
    return `<i class="${this.escapeHtml(cfg.icon_base || "fas fa-circle")}${spin} ${this.escapeHtml(color)}" style="font-size: 12px;" title="${this.escapeHtml(cfg.label || key)}" aria-hidden="true"></i>`
  }

  h5adCellHtml(item) {
    const status = item.h5ad_status || "missing"
    const icon = this.statusIconHtml(status, item.h5ad_status_id)
    const loomName = this.escapeHtml(item.name || "")
    if (status === "ready") {
      return `<div class="flex items-center gap-2">${icon}<a href="${this.escapeHtml(item.url_h5ad)}" target="_blank" rel="noopener noreferrer" class="text-blue-700 hover:text-blue-900 hover:underline font-medium">Download H5AD</a></div>`
    }
    if (status === "pending" || status === "running") {
      const label = status === "running" ? "Exporting" : "Queued"
      return `<div class="flex items-center gap-2">${icon}<span class="text-gray-600 text-sm">${label}</span></div>`
    }
    const label = status === "failed" ? "Retry export" : (status === "stale" ? "Re-export H5AD" : "Export H5AD")
    return `<div class="flex items-center gap-2">${icon}<button type="button" class="text-blue-700 hover:text-blue-900 hover:underline font-medium" data-h5ad-export-loom="${loomName}">${label}</button></div>`
  }

  needsPolling(items) {
    return Array.isArray(items) && items.some((item) => {
      const s = item && item.h5ad_status
      return s === "pending" || s === "running"
    })
  }

  loomTableHtml(items) {
    if (!Array.isArray(items) || items.length === 0) {
      return '<p class="text-gray-500 italic">No Loom files listed.</p>'
    }
    const rows = items.map((item) => {
      const loomLabel = this.escapeHtml(item.run_name || item.name || "Loom file")
      const sub = item.file_size ? `<span class="block text-xs text-gray-500 mt-0.5">${this.escapeHtml(item.file_size)}</span>` : ""
      const attrs = item.run_attrs ? `<div class="mt-1">${item.run_attrs}</div>` : ""
      return `<tr class="border-b border-gray-100 align-top">
          <td class="py-2 pr-3"><a href="${this.escapeHtml(item.url)}" target="_blank" rel="noopener noreferrer" class="text-blue-700 hover:text-blue-900 hover:underline font-medium">${loomLabel}</a>${sub}</td>
          <td class="py-2 pr-3">${this.h5adCellHtml(item)}</td>
          <td class="py-2 text-gray-600">${attrs}</td>
        </tr>`
    }).join("")
    return `<div class="overflow-x-auto"><table class="min-w-full text-left"><thead><tr class="border-b border-gray-200 text-xs font-medium text-gray-500 uppercase tracking-wide">
        <th class="pb-2 pr-3">Loom file</th>
        <th class="pb-2 pr-3">H5AD file</th>
        <th class="pb-2">Run attributes</th>
      </tr></thead><tbody>${rows}</tbody></table></div>`
  }

  dnaAccessibilityHtml(items) {
    if (!Array.isArray(items) || items.length === 0) return ""
    const rows = items.map((item) => {
      const label = this.escapeHtml(item.label)
      const filename = `<span class="block text-xs text-gray-500 mt-0.5">${this.escapeHtml(item.name)}</span>`
      const size = item.file_size ? `<span class="block text-xs text-gray-500">${this.escapeHtml(item.file_size)}</span>` : ""
      const download = item.present
        ? `<a href="${this.escapeHtml(item.url)}" target="_blank" rel="noopener noreferrer" class="text-blue-700 hover:text-blue-900 hover:underline font-medium">Download</a>`
        : '<span class="text-gray-500">Not available</span>'
      return `<tr class="border-b border-gray-100 align-top">
          <td class="py-2 pr-3">${label}${filename}${size}</td>
          <td class="py-2">${download}</td>
        </tr>`
    }).join("")
    return `<div class="mt-6">
        <h4 class="text-xs font-medium text-gray-500 uppercase tracking-wide mb-2">DNA accessibility</h4>
        <div class="overflow-x-auto"><table class="min-w-full text-left"><thead><tr class="border-b border-gray-200 text-xs font-medium text-gray-500 uppercase tracking-wide">
          <th class="pb-2 pr-3">File</th>
          <th class="pb-2">Download</th>
        </tr></thead><tbody>${rows}</tbody></table></div>
      </div>`
  }

  renderRows(payload) {
    const items = payload.files
    const dnaItems = payload.atac ? payload.dna_accessibility : []
    this.latestItems = items
    this.bodyTarget.innerHTML = this.loomTableHtml(items) + this.dnaAccessibilityHtml(dnaItems)
    if (this.needsPolling(items)) this.startPolling()
    else this.stopPolling()
  }

  async fetchList() {
    const url = this.jsonUrlValue
    if (!url) throw new Error("Missing data URL")
    const response = await fetch(url, { headers: { Accept: "application/json" }, credentials: "same-origin" })
    const data = await response.json()
    if (!response.ok) {
      const message = (data && data.error) ? data.error : "Request failed."
      throw new Error(message)
    }
    if (data && data.error) throw new Error(data.error)
    if (!data || !Array.isArray(data.files)) throw new Error("Invalid file list payload.")
    if (data.atac && !Array.isArray(data.dna_accessibility)) throw new Error("Invalid DNA accessibility payload.")
    return data
  }

  startPolling() {
    if (this.pollTimer) return
    this.pollTimer = setInterval(async () => {
      if (!this.isOpen()) {
        this.stopPolling()
        return
      }
      try {
        const data = await this.fetchList()
        this.renderRows(data)
      } catch (_err) {
        // Keep last render; next tick may succeed.
      }
    }, 3000)
  }

  async startExport(loomPath) {
    const exportUrl = this.exportUrlValue
    if (!exportUrl) {
      this.bodyTarget.insertAdjacentHTML("afterbegin", '<p class="text-red-600 mb-2">Missing export URL.</p>')
      return
    }
    const response = await fetch(exportUrl, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify({ input_loom: loomPath })
    })
    const data = await response.json().catch(() => ({}))
    if (!response.ok) {
      const message = (data && data.error) ? data.error : "Export failed to start."
      throw new Error(message)
    }
    const refreshed = await this.fetchList()
    this.renderRows(refreshed)
  }

  handleBodyClick(event) {
    const btn = event.target.closest("[data-h5ad-export-loom]")
    if (!btn) return
    event.preventDefault()
    event.stopPropagation()
    const loomPath = btn.getAttribute("data-h5ad-export-loom")
    if (!loomPath) return
    btn.disabled = true
    this.startExport(loomPath).catch((err) => {
      btn.disabled = false
      const msg = err && err.message ? err.message : "Export failed to start."
      this.bodyTarget.insertAdjacentHTML("afterbegin", `<p class="text-red-600 mb-2">${this.escapeHtml(msg)}</p>`)
    })
  }

  async loadAndShow() {
    if (!this.hasBodyTarget) return
    if (!this.jsonUrlValue) {
      this.bodyTarget.innerHTML = '<p class="text-red-600">Missing data URL.</p>'
      this.open()
      return
    }
    this.bodyTarget.innerHTML = '<p class="text-gray-500">Loading</p>'
    this.open()
    try {
      const data = await this.fetchList()
      this.renderRows(data)
    } catch (err) {
      const message = err && err.message ? err.message : "Unable to load file list."
      this.bodyTarget.innerHTML = `<p class="text-red-600">${this.escapeHtml(message)}</p>`
    }
  }
}
