// Popup that ranks gene sets by overlap with a selected gene list.
export class GeneSetOverlapPopup {
  constructor(options = {}) {
    this.getProjectIdentifier = options.getProjectIdentifier || (() => null)
    this.getGenes = options.getGenes || (() => [])
    this.getCsrfToken = options.getCsrfToken || (() => {
      return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
    })
    this.overlay = null
  }

  open() {
    const genes = this.normalizeGenes(this.getGenes())
    if (!genes.length) {
      alert("Select at least one gene first.")
      return
    }
    this.close()
    this.overlay = this.buildOverlay(genes.length)
    document.body.appendChild(this.overlay)
    this.loadResults(genes)
  }

  close() {
    if (this.overlay) {
      this.overlay.remove()
      this.overlay = null
    }
  }

  normalizeGenes(rawGenes) {
    const seen = new Set()
    const genes = []
    for (const gene of Array.isArray(rawGenes) ? rawGenes : []) {
      const symbol = String(gene?.symbol || gene?.query || "").trim()
      const ensemblId = String(gene?.ensembl_id || gene?.ensemblId || "").trim()
      const stableId = String(gene?.stable_id || gene?.stableId || "").trim()
      if (!symbol && !ensemblId) continue
      const key = `${symbol.toLowerCase()}|${ensemblId.toLowerCase()}`
      if (seen.has(key)) continue
      seen.add(key)
      genes.push({
        symbol,
        ensembl_id: ensemblId,
        stable_id: stableId
      })
    }
    return genes
  }

  buildOverlay(geneCount) {
    const overlay = document.createElement("div")
    overlay.id = "gene-set-overlap-modal-overlay"
    overlay.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:14000;display:flex;align-items:center;justify-content:center;padding:20px;"
    overlay.innerHTML = `
      <div data-role="gene-set-overlap-panel" style="background:#fff;border-radius:8px;padding:20px;max-width:720px;width:100%;max-height:85vh;overflow:hidden;box-shadow:0 20px 25px -5px rgba(0,0,0,0.1);display:flex;flex-direction:column;gap:12px;">
        <div style="display:flex;justify-content:space-between;align-items:center;gap:12px;">
          <div>
            <h3 style="margin:0;font-size:18px;font-weight:600;color:#111827;">Gene sets overlapping selected genes</h3>
            <div data-role="gene-set-overlap-subtitle" style="margin-top:4px;font-size:12px;color:#6b7280;">
              Ranking gene sets by overlap with the ${geneCount} selected gene${geneCount === 1 ? "" : "s"} (percentage is share of each gene set covered)
            </div>
          </div>
          <button type="button" data-role="gene-set-overlap-close" style="background:none;border:none;font-size:22px;color:#6b7280;cursor:pointer;line-height:1;">x</button>
        </div>
        <div data-role="gene-set-overlap-status" style="font-size:13px;color:#6b7280;">Loading gene sets...</div>
        <div data-role="gene-set-overlap-list" style="flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:6px;"></div>
        <div style="display:flex;justify-content:flex-end;padding-top:8px;border-top:1px solid #e5e7eb;">
          <button type="button" data-role="gene-set-overlap-close"
                  style="padding:8px 14px;background:#e5e7eb;color:#374151;border:none;border-radius:6px;font-size:13px;cursor:pointer;">
            Close
          </button>
        </div>
      </div>
    `

    overlay.addEventListener("click", (event) => {
      if (event.target === overlay) this.close()
    })
    overlay.querySelectorAll('[data-role="gene-set-overlap-close"]').forEach((btn) => {
      btn.addEventListener("click", (event) => {
        event.preventDefault()
        this.close()
      })
    })
    return overlay
  }

  setStatus(message, { error = false } = {}) {
    const statusEl = this.overlay?.querySelector('[data-role="gene-set-overlap-status"]')
    if (!statusEl) return
    statusEl.textContent = message || ""
    statusEl.style.color = error ? "#b91c1c" : "#6b7280"
  }

  async loadResults(genes) {
    const projectIdentifier = this.getProjectIdentifier()
    if (!projectIdentifier) {
      this.setStatus("Project identifier is missing.", { error: true })
      return
    }

    try {
      const response = await fetch(`/projects/${encodeURIComponent(projectIdentifier)}/search_gene_set_overlaps`, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this.getCsrfToken()
        },
        body: JSON.stringify({ genes, limit: 100 })
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok || payload.status !== "ok") {
        throw new Error(payload.message || "Failed to rank gene sets")
      }
      this.renderResults(payload)
    } catch (error) {
      this.setStatus(error.message || "Failed to rank gene sets", { error: true })
      const listEl = this.overlay?.querySelector('[data-role="gene-set-overlap-list"]')
      if (listEl) listEl.innerHTML = ""
    }
  }

  escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  renderResults(payload) {
    const items = Array.isArray(payload.items) ? payload.items : []
    const queryCount = Number(payload.query_gene_count || 0)
    const unresolved = Number(payload.unresolved_count || 0)
    const subtitle = this.overlay?.querySelector('[data-role="gene-set-overlap-subtitle"]')
    if (subtitle) {
      let text = `Percentage is the share of each gene set covered by the ${queryCount} resolved gene${queryCount === 1 ? "" : "s"}`
      if (unresolved > 0) text += ` (${unresolved} unresolved)`
      subtitle.textContent = text
    }

    if (!items.length) {
      this.setStatus("No overlapping gene sets found for the selected genes.")
      const listEl = this.overlay?.querySelector('[data-role="gene-set-overlap-list"]')
      if (listEl) listEl.innerHTML = ""
      return
    }

    this.setStatus(`${items.length} gene set${items.length === 1 ? "" : "s"} ranked by overlap`)
    const listEl = this.overlay?.querySelector('[data-role="gene-set-overlap-list"]')
    if (!listEl) return

    listEl.innerHTML = items.map((item) => {
      const name = this.escapeHtml(item.name || item.identifier || "Unnamed gene set")
      const collection = this.escapeHtml(item.collection_label || "Collection")
      const pct = Number(item.overlap_pct || 0)
      const overlap = Number(item.overlap_count || 0)
      const setSize = Number(item.gene_set_size || 0)
      const queryCountForItem = Number(item.query_gene_count || queryCount || 0)
      const typeLabel = this.escapeHtml(item.type_label || "")
      const typeIcon = this.escapeHtml(item.type_icon || "fas fa-folder")
      const typeColor = this.escapeHtml(item.type_icon_color || "#6b7280")
      return `
        <div style="display:flex;align-items:flex-start;justify-content:space-between;gap:12px;padding:10px 12px;border:1px solid #e5e7eb;border-radius:8px;background:#fff;">
          <div style="min-width:0;flex:1;">
            <div style="display:flex;align-items:center;gap:6px;min-width:0;">
              <span title="${typeLabel}" aria-label="${typeLabel}" style="display:inline-flex;align-items:center;justify-content:center;width:16px;height:16px;color:${typeColor};flex:0 0 auto;">
                <i class="${typeIcon}" style="font-size:10px;"></i>
              </span>
              <div style="font-size:13px;font-weight:600;color:#111827;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">${name}</div>
            </div>
            <div style="margin-top:2px;font-size:12px;color:#6b7280;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">${collection}</div>
          </div>
          <div style="flex:0 0 auto;text-align:right;">
            <div style="font-size:14px;font-weight:700;color:#0f766e;">${pct.toFixed(1)}%</div>
            <div style="font-size:11px;color:#6b7280;">${overlap} / ${setSize} of set</div>
            <div style="font-size:11px;color:#9ca3af;">${overlap} / ${queryCountForItem} of selected</div>
          </div>
        </div>
      `
    }).join("")
  }
}
