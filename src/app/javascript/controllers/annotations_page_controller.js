import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "scopeSelect",
    "typeSelect",
    "metadataSelect",
    "textFilter",
    "projectList",
    "tableBody",
    "emptyState",
    "status",
    "createConsensusButton",
    "consensusMetadataLinks",
    "consensusSupportBanner",
    "cellSetFilterChip",
    "modal",
    "modalBody",
    "modalStatus",
    "validateButton"
  ]

  static values = {
    projectId: Number,
    relatedUrl: String,
    federatedUrl: String,
    previewUrl: String,
    exportUrl: String,
    supportUrl: String,
    canExport: String,
    initialPayload: Object,
    initialProjects: Array,
    initialSupport: Object
  }

  connect() {
    this.projects = Array.isArray(this.initialProjectsValue) ? this.initialProjectsValue : []
    this.payload = this.initialPayloadValue || {
      annotations: [],
      annotation_type_options: [],
      annotation_metadata_by_type: {},
      consensus_metadata_by_type: {}
    }
    this.consensusSupportByType = this.initialSupportValue || {}
    this.cellSetKeyFilter = ""
    this.preview = null
    this.equalRankChoices = {}
    this.collisionChoices = {}
    this.renderProjects()
    this.syncMetadataOptions()
    this.renderConsensusMetadataLinks()
    this.renderConsensusSupportBanner()
    this.renderCellSetFilterChip()
    this.renderTable()
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  selectedProjectIds() {
    if (!this.hasProjectListTarget) return [this.projectIdValue]
    const checked = Array.from(this.projectListTarget.querySelectorAll('input[type="checkbox"]:checked'))
    const ids = checked.map((el) => Number(el.value)).filter((id) => id > 0)
    return ids.length > 0 ? ids : [this.projectIdValue]
  }

  setStatus(message, isError = false) {
    if (!this.hasStatusTarget) return
    if (!message) {
      this.statusTarget.classList.add("hidden")
      this.statusTarget.textContent = ""
      return
    }
    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("hidden")
    this.statusTarget.classList.toggle("text-red-600", !!isError)
    this.statusTarget.classList.toggle("text-gray-600", !isError)
  }

  setModalStatus(message, isError = false) {
    if (!this.hasModalStatusTarget) return
    this.modalStatusTarget.textContent = message || ""
    this.modalStatusTarget.classList.toggle("text-red-600", !!isError)
    this.modalStatusTarget.classList.toggle("text-gray-600", !isError)
  }

  async scopeChanged() {
    const scope = this.scopeSelectTarget.value
    this.setStatus("Loading related projects...", false)
    try {
      const url = new URL(this.relatedUrlValue, window.location.origin)
      url.searchParams.set("scope", scope)
      const response = await fetch(url.toString(), {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok || payload.status !== "ok") {
        throw new Error(payload.message || "Failed to load related projects")
      }
      this.projects = Array.isArray(payload.projects) ? payload.projects : []
      this.renderProjects()
      await this.reloadAnnotations()
      this.setStatus("", false)
    } catch (error) {
      this.setStatus(error.message || "Failed to load related projects", true)
    }
  }

  selectAllProjects() {
    this.projectListTarget.querySelectorAll('input[type="checkbox"]').forEach((el) => { el.checked = true })
    this.reloadAnnotations()
  }

  clearAllProjects() {
    this.projectListTarget.querySelectorAll('input[type="checkbox"]').forEach((el) => { el.checked = false })
    this.reloadAnnotations()
  }

  projectsSelectionChanged() {
    this.reloadAnnotations()
  }

  renderProjects() {
    if (!this.hasProjectListTarget) return
    if (!this.projects.length) {
      this.projectListTarget.innerHTML = '<p class="text-xs text-gray-500 italic">No readable projects in this scope.</p>'
      return
    }
    this.projectListTarget.innerHTML = this.projects.map((project) => {
      const id = project.id
      const key = this.escapeHtml(project.key || "")
      const name = this.escapeHtml(project.name || project.key || "")
      const currentBadge = project.is_current
        ? '<span class="ml-2 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-semibold bg-emerald-100 text-emerald-800">current</span>'
        : ""
      return `
        <label class="flex items-start gap-2 text-xs text-gray-700 cursor-pointer">
          <input type="checkbox" class="mt-0.5" value="${id}" checked
                 data-action="change->annotations-page#projectsSelectionChanged">
          <span><span class="font-mono">${key}</span> - ${name}${currentBadge}</span>
        </label>
      `
    }).join("")
  }

  async reloadAnnotations() {
    const ids = this.selectedProjectIds()
    const url = new URL(this.federatedUrlValue, window.location.origin)
    ids.forEach((id) => url.searchParams.append("project_ids[]", id))
    this.setStatus("Loading annotations...", false)
    try {
      const response = await fetch(url.toString(), {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok || payload.status !== "ok") {
        throw new Error(payload.message || "Failed to load annotations")
      }
      this.payload = payload
      this.rebuildTypeOptions()
      this.syncMetadataOptions()
      this.renderConsensusMetadataLinks()
      this.renderTable()
      this.setStatus("", false)
    } catch (error) {
      this.setStatus(error.message || "Failed to load annotations", true)
    }
  }

  rebuildTypeOptions() {
    if (!this.hasTypeSelectTarget) return
    const previous = String(this.typeSelectTarget.value || "")
    const options = Array.isArray(this.payload.annotation_type_options) ? this.payload.annotation_type_options : []
    this.typeSelectTarget.innerHTML = options.map((opt) => {
      const id = opt.id == null ? "" : String(opt.id)
      const label = opt.label || "Unspecified"
      const count = Number(opt.count || 0)
      const tag = opt.tag || ""
      return `<option value="${this.escapeAttr(id)}" data-tag="${this.escapeAttr(tag)}">${this.escapeHtml(label)} (${count.toLocaleString()})</option>`
    }).join("")
    const ids = options.map((opt) => (opt.id == null ? "" : String(opt.id)))
    this.typeSelectTarget.value = ids.includes(previous) ? previous : (ids.find((id) => id !== "") || ids[0] || "")
    if (this.hasCreateConsensusButtonTarget) {
      this.createConsensusButtonTarget.disabled = String(this.typeSelectTarget.value || "") === ""
    }
  }

  syncMetadataOptions() {
    if (!this.hasMetadataSelectTarget || !this.hasTypeSelectTarget) return
    const typeId = String(this.typeSelectTarget.value || "")
    const byType = this.payload.annotation_metadata_by_type || {}
    const options = Array.isArray(byType[typeId]) ? byType[typeId] : []
    const previous = String(this.metadataSelectTarget.value || "")
    this.metadataSelectTarget.innerHTML = '<option value="">All</option>' + options.map((opt) => {
      const id = opt.id == null ? "" : String(opt.id)
      const label = opt.label || "Metadata"
      const count = Number(opt.count || 0)
      return `<option value="${this.escapeAttr(id)}">${this.escapeHtml(label)} (${count.toLocaleString()})</option>`
    }).join("")
    const ids = options.map((opt) => (opt.id == null ? "" : String(opt.id)))
    this.metadataSelectTarget.value = ids.includes(previous) ? previous : ""
  }

  filtersChanged() {
    this.syncMetadataOptions()
    this.renderConsensusMetadataLinks()
    this.renderConsensusSupportBanner()
    this.renderCellSetFilterChip()
    this.renderTable()
    if (this.hasCreateConsensusButtonTarget) {
      this.createConsensusButtonTarget.disabled = String(this.typeSelectTarget.value || "") === ""
    }
  }

  filterByCellSet(event) {
    const key = event.currentTarget?.dataset?.cellSetKey || ""
    if (!key) return
    this.cellSetKeyFilter = key
    this.renderCellSetFilterChip()
    this.renderTable()
  }

  clearCellSetFilter(event) {
    if (event) event.preventDefault()
    this.cellSetKeyFilter = ""
    this.renderCellSetFilterChip()
    this.renderTable()
  }

  renderCellSetFilterChip() {
    if (!this.hasCellSetFilterChipTarget) return
    const key = String(this.cellSetKeyFilter || "")
    if (!key) {
      this.cellSetFilterChipTarget.classList.add("hidden")
      this.cellSetFilterChipTarget.innerHTML = ""
      return
    }
    const shortKey = key.length > 10 ? `${key.slice(0, 10)}...` : key
    this.cellSetFilterChipTarget.innerHTML =
      `Filtered by cell set <span class="font-mono">${this.escapeHtml(shortKey)}</span> ` +
      `<button type="button" class="text-blue-700 hover:underline ml-1" data-action="click->annotations-page#clearCellSetFilter">Clear</button>`
    this.cellSetFilterChipTarget.classList.remove("hidden")
  }

  renderConsensusSupportBanner() {
    if (!this.hasConsensusSupportBannerTarget) return
    const hasTypeSelect = this.hasTypeSelectTarget && this.typeSelectTarget.options.length > 0
    // Empty string is a valid type id for "Unspecified" annotations (nil ontology_term_type_id).
    const typeId = hasTypeSelect ? String(this.typeSelectTarget.value || "") : null
    const entry = typeId == null ? null : (this.consensusSupportByType[typeId] || null)
    const banner = this.consensusSupportBannerTarget

    let messages = Array.isArray(entry?.messages) ? entry.messages.slice() : []
    if (typeId != null && !entry) {
      const hasAsapManual = (Array.isArray(this.payload.annotations) ? this.payload.annotations : []).some((row) => {
        const rowType = row.ontology_term_type_id == null ? "" : String(row.ontology_term_type_id)
        return rowType === typeId && String(row.origin || "") === "ASAP manual"
      })
      if (hasAsapManual) {
        const selected = this.typeSelectTarget.selectedOptions?.[0]
        const typeLabel = (selected?.textContent || "this annotation type").replace(/\s*\(\d[\d,]*\)\s*$/, "").trim()
        const tag = selected?.dataset?.tag || ""
        const text = tag
          ? `No consensus annotation exists for annotation type ${typeLabel}, but ASAP manual annotations are present. Expected metadata: /col_attrs/_asap_consensus_${tag} and /col_attrs/_asap_consensus_${tag}_ontology_term_id.`
          : `No consensus annotation exists for annotation type ${typeLabel}, but ASAP manual annotations are present. Assign an annotation type to those annotations before creating consensus metadata.`
        messages = [{
          level: "error",
          code: "missing_consensus",
          text
        }]
      }
    }

    if (typeId == null || messages.length === 0) {
      banner.classList.add("hidden")
      banner.innerHTML = ""
      return
    }

    const levelClasses = {
      error: "border-red-300 bg-red-50 text-red-900",
      warning: "border-amber-300 bg-amber-50 text-amber-900",
      success: "border-emerald-300 bg-emerald-50 text-emerald-900"
    }
    const roleFor = { error: "alert", warning: "status", success: "status" }

    banner.innerHTML = messages.map((msg) => {
      const level = ["error", "warning", "success"].includes(msg.level) ? msg.level : "error"
      const text = this.escapeHtml(msg.text || msg.message || "")
      if (!text) return ""
      return `<div class="rounded-md border px-4 py-3 text-sm ${levelClasses[level]}" role="${roleFor[level]}">${text}</div>`
    }).filter(Boolean).join("")

    banner.classList.toggle("hidden", banner.innerHTML.trim() === "")
  }

  async reloadConsensusSupport() {
    if (!this.supportUrlValue) return
    try {
      const response = await fetch(this.supportUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok || payload.status !== "ok") return
      this.consensusSupportByType = payload.by_type || {}
      this.renderConsensusSupportBanner()
    } catch (_error) {
      // Keep the previous support state if refresh fails.
    }
  }

  renderConsensusMetadataLinks() {
    if (!this.hasConsensusMetadataLinksTarget) return
    const typeId = this.hasTypeSelectTarget ? String(this.typeSelectTarget.value || "") : ""
    const byType = this.payload.consensus_metadata_by_type || {}
    const entry = typeId ? (byType[typeId] || null) : null
    if (!entry) {
      this.consensusMetadataLinksTarget.innerHTML = ""
      return
    }

    const parts = [entry.label, entry.ontology_term_id].filter(Boolean).map((meta) => {
      const label = this.escapeHtml(meta.name || meta.path || "")
      if (!label) return ""
      if (meta.url) {
        return `<a href="${this.escapeAttr(meta.url)}" class="text-emerald-700 hover:underline font-mono whitespace-nowrap">${label}</a>`
      }
      return `<span class="font-mono whitespace-nowrap text-gray-400" title="Not present on this project yet">${label}</span>`
    }).filter(Boolean)

    if (!parts.length) {
      this.consensusMetadataLinksTarget.innerHTML = ""
      return
    }
    this.consensusMetadataLinksTarget.innerHTML = ` (${parts.join(", ")})`
  }

  renderTable() {
    if (!this.hasTableBodyTarget) return
    const typeId = this.hasTypeSelectTarget ? String(this.typeSelectTarget.value || "") : ""
    const annotId = this.hasMetadataSelectTarget ? String(this.metadataSelectTarget.value || "") : ""
    const query = this.hasTextFilterTarget ? String(this.textFilterTarget.value || "").trim().toLowerCase() : ""
    const cellSetKeyFilter = String(this.cellSetKeyFilter || "")
    const rows = Array.isArray(this.payload.annotations) ? this.payload.annotations : []
    const visible = rows.filter((row) => {
      const rowType = row.ontology_term_type_id == null ? "" : String(row.ontology_term_type_id)
      if (rowType !== typeId) return false
      if (annotId && String(row.annot_id || "") !== annotId) return false
      if (cellSetKeyFilter && String(row.cell_set_key || "") !== cellSetKeyFilter) return false
      if (!query) return true
      const haystack = [
        row.project_key, row.project_name, row.metadata_name, row.cluster_category,
        row.label, row.origin, row.cell_set_key, row.created_by
      ].map((v) => String(v || "").toLowerCase()).join(" ")
      return haystack.includes(query)
    })

    this.tableBodyTarget.innerHTML = visible.map((row) => {
      const projectLabel = row.is_current || Number(row.project_id) === Number(this.projectIdValue)
        ? `<span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-semibold bg-emerald-100 text-emerald-800 mr-1">current</span>`
        : ""
      const cellSetKey = String(row.cell_set_key || "")
      const cellSet = cellSetKey
        ? `<button type="button"
                   class="text-blue-700 hover:text-blue-900 hover:underline font-mono"
                   title="${this.escapeAttr(cellSetKey)}"
                   data-cell-set-key="${this.escapeAttr(cellSetKey)}"
                   data-action="click->annotations-page#filterByCellSet">${this.escapeHtml(cellSetKey.slice(0, 10))}...</button>`
        : "-"
      const consensusIcon = row.in_consensus
        ? `<i class="fas fa-check-circle text-emerald-600" title="Present in ASAP consensus metadata"></i>`
        : `<span class="text-gray-300" title="Not present in ASAP consensus metadata">-</span>`
      return `
        <tr class="${row.in_consensus ? "bg-emerald-50/40" : ""}">
          <td class="px-2 py-1.5 text-xs text-gray-700">${projectLabel}<span class="font-mono">${this.escapeHtml(row.project_key || "")}</span> ${this.escapeHtml(row.project_name || "")}</td>
          <td class="px-2 py-1.5 text-xs text-gray-700 whitespace-nowrap">${this.escapeHtml(row.metadata_name || "-")}</td>
          <td class="px-2 py-1.5 text-xs text-gray-700">${this.escapeHtml(row.cluster_category || "-")}</td>
          <td class="px-2 py-1.5 text-xs text-gray-700">${this.escapeHtml(row.label || "-")}</td>
          <td class="px-2 py-1.5 text-xs text-center">${consensusIcon}</td>
          <td class="px-2 py-1.5 text-xs text-gray-600 whitespace-nowrap">${this.escapeHtml(row.origin || "-")}</td>
          <td class="px-2 py-1.5 text-xs text-gray-600 whitespace-nowrap">${cellSet}</td>
          <td class="px-2 py-1.5 text-xs text-gray-600 whitespace-nowrap">+${Number(row.nber_agree || 0).toLocaleString()} / -${Number(row.nber_disagree || 0).toLocaleString()}</td>
          <td class="px-2 py-1.5 text-xs text-gray-600 whitespace-nowrap">${this.escapeHtml(row.created_by || "-")}</td>
          <td class="px-2 py-1.5 text-xs text-gray-600 whitespace-nowrap">${this.escapeHtml(row.created_at || "-")}</td>
        </tr>
      `
    }).join("")

    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.toggle("hidden", visible.length > 0)
    }
  }

  async openConsensusPreview() {
    if (this.canExportValue !== "1") {
      this.setStatus("Only the project owner can create consensus metadata.", true)
      return
    }
    const typeId = String(this.typeSelectTarget.value || "")
    if (!typeId) {
      this.setStatus("Select an annotation type first.", true)
      return
    }
    this.equalRankChoices = {}
    this.collisionChoices = {}
    this.setStatus("Building consensus preview...", false)
    try {
      await this.fetchPreview()
      this.openModal()
      this.renderPreviewModal()
      this.setStatus("", false)
    } catch (error) {
      this.setStatus(error.message || "Failed to preview consensus", true)
    }
  }

  async fetchPreview() {
    const response = await fetch(this.previewUrlValue, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      credentials: "same-origin",
      body: JSON.stringify({
        ontology_term_type_id: this.typeSelectTarget.value,
        project_ids: this.selectedProjectIds(),
        equal_rank_choices: this.equalRankChoices,
        collision_choices: this.collisionChoices
      })
    })
    const payload = await response.json().catch(() => ({}))
    if (!response.ok || payload.status !== "ok") {
      throw new Error(payload.message || payload.error || "Failed to preview consensus")
    }
    this.preview = payload
    return payload
  }

  openModal() {
    if (this.hasModalTarget) this.modalTarget.classList.remove("hidden")
  }

  closeModal() {
    if (this.hasModalTarget) this.modalTarget.classList.add("hidden")
    this.setModalStatus("", false)
  }

  backdropClose(event) {
    if (event.target === this.modalTarget) this.closeModal()
  }

  stopPropagation(event) {
    event.stopPropagation()
  }

  renderPreviewModal() {
    if (!this.hasModalBodyTarget || !this.preview) return
    const equalRank = Array.isArray(this.preview.equal_rank) ? this.preview.equal_rank : []
    const collisions = Array.isArray(this.preview.collisions) ? this.preview.collisions : []

    let html = `
      <p class="text-sm text-gray-700">
        Consensus for <strong>${this.escapeHtml(this.preview.annotation_type_label || "annotation")}</strong>
        will be written to <code>${this.escapeHtml(this.preview.metadata_path || "")}</code>
        on the current project loom.
      </p>
    `

    if (equalRank.length === 0 && collisions.length === 0) {
      html += `<p class="text-sm text-emerald-700">No equal-rank ties or cell-set collisions detected. You can validate to create the consensus metadata.</p>`
    }

    if (equalRank.length > 0) {
      html += `<div><h3 class="text-sm font-semibold text-amber-800 mb-2">Equal-rank annotations</h3>
        <p class="text-xs text-gray-600 mb-2">These cell sets have different annotations with the same score. Choose one with the radio buttons.</p>
        <div class="space-y-3">`
      equalRank.forEach((row) => {
        const selected = this.equalRankChoices[String(row.cell_set_id)] || row.selected_cla_id
        html += `<div class="border border-amber-200 bg-amber-50 rounded p-3" data-equal-rank-id="${this.escapeAttr(row.id)}">
          <div class="text-xs text-gray-700 mb-2">Cell set <span class="font-mono">${this.escapeHtml((row.cell_set_key || "").slice(0, 12))}...</span>
            (${Number(row.nber_cells || 0).toLocaleString()} cells, score ${row.score})</div>
          <div class="space-y-2">`
        ;(row.candidates || []).forEach((candidate) => {
          const checked = Number(selected) === Number(candidate.cla_id) ? "checked" : ""
          html += `<label class="flex items-start gap-2 text-xs text-gray-800 cursor-pointer">
            <input type="radio" name="equal-rank-${row.cell_set_id}" value="${candidate.cla_id}" ${checked}
                   data-action="change->annotations-page#equalRankChanged"
                   data-cell-set-id="${row.cell_set_id}">
            <span>
              <span class="font-medium">${this.escapeHtml(candidate.label)}</span>
              in ${this.escapeHtml(candidate.metadata_name)} / ${this.escapeHtml(candidate.category)}
              (project <span class="font-mono">${this.escapeHtml(candidate.project_key)}</span>)
            </span>
          </label>`
        })
        html += `</div></div>`
      })
      html += `</div></div>`
    }

    if (collisions.length > 0) {
      html += `<div><h3 class="text-sm font-semibold text-indigo-800 mb-2">Cell-set collisions</h3>
        <p class="text-xs text-gray-600 mb-2">Preferred annotation is highlighted. Check "Use alternative" to override first-write assignment. Related collisions are highlighted when a choice would affect them.</p>
        <div class="overflow-x-auto"><table class="min-w-full text-xs border border-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-2 py-1.5 text-left">Overlap cells</th>
              <th class="px-2 py-1.5 text-left">Preferred</th>
              <th class="px-2 py-1.5 text-left">Alternative</th>
              <th class="px-2 py-1.5 text-left">Use alternative</th>
            </tr>
          </thead>
          <tbody>`
      collisions.forEach((row) => {
        const useAlt = this.collisionChoices[row.id] === 1 || row.use_alternative
        const preferredClass = useAlt ? "bg-white" : "bg-emerald-50"
        const alternativeClass = useAlt ? "bg-emerald-50" : "bg-white"
        html += `<tr data-collision-id="${this.escapeAttr(row.id)}" data-affects="${this.escapeAttr((row.affects || []).join(","))}">
          <td class="px-2 py-1.5 border-t">${Number(row.overlap_cell_count || 0).toLocaleString()}</td>
          <td class="px-2 py-1.5 border-t ${preferredClass}">${this.renderAnnotationCell(row.preferred)}</td>
          <td class="px-2 py-1.5 border-t ${alternativeClass}">${this.renderAnnotationCell(row.alternative)}</td>
          <td class="px-2 py-1.5 border-t">
            <input type="checkbox" ${useAlt ? "checked" : ""}
                   data-action="change->annotations-page#collisionChanged"
                   data-collision-id="${this.escapeAttr(row.id)}">
          </td>
        </tr>`
      })
      html += `</tbody></table></div></div>`
    }

    this.modalBodyTarget.innerHTML = html
    this.refreshValidateEnabled()
  }

  renderAnnotationCell(entry) {
    if (!entry) return "-"
    return `<div>
      <div class="font-medium">${this.escapeHtml(entry.label || "-")}</div>
      <div class="text-gray-600">${this.escapeHtml(entry.metadata_name || "-")} / ${this.escapeHtml(entry.category || "-")}</div>
      <div class="text-gray-500">project <span class="font-mono">${this.escapeHtml(entry.project_key || "")}</span> (score ${entry.score})</div>
    </div>`
  }

  async equalRankChanged(event) {
    const cellSetId = event.target.dataset.cellSetId
    this.equalRankChoices[String(cellSetId)] = Number(event.target.value)
    this.clearConsequenceHighlights()
    try {
      this.setModalStatus("Updating preview...", false)
      await this.fetchPreview()
      this.renderPreviewModal()
      this.setModalStatus("", false)
    } catch (error) {
      this.setModalStatus(error.message || "Failed to update preview", true)
    }
  }

  async collisionChanged(event) {
    const collisionId = event.target.dataset.collisionId
    this.collisionChoices[collisionId] = event.target.checked ? 1 : 0
    const row = event.target.closest("tr")
    const affects = (row?.dataset?.affects || "").split(",").filter(Boolean)
    this.highlightConsequences([collisionId, ...affects])
    try {
      this.setModalStatus("Updating preview and related collisions...", false)
      await this.fetchPreview()
      this.renderPreviewModal()
      this.highlightConsequences(affects)
      this.setModalStatus(
        affects.length
          ? `This choice may affect ${affects.length} related collision(s), highlighted below.`
          : "",
        false
      )
    } catch (error) {
      this.setModalStatus(error.message || "Failed to update preview", true)
    }
  }

  highlightConsequences(ids) {
    if (!this.hasModalBodyTarget) return
    this.modalBodyTarget.querySelectorAll("[data-collision-id]").forEach((el) => {
      const active = ids.includes(el.dataset.collisionId)
      el.classList.toggle("ring-2", active)
      el.classList.toggle("ring-amber-400", active)
    })
  }

  clearConsequenceHighlights() {
    this.highlightConsequences([])
  }

  refreshValidateEnabled() {
    if (!this.hasValidateButtonTarget || !this.preview) return
    const equalRank = Array.isArray(this.preview.equal_rank) ? this.preview.equal_rank : []
    const unresolved = equalRank.some((row) => {
      const selected = this.equalRankChoices[String(row.cell_set_id)] || row.selected_cla_id
      return !selected
    })
    this.validateButtonTarget.disabled = unresolved
  }

  async validateConsensus() {
    if (this.canExportValue !== "1") return
    this.validateButtonTarget.disabled = true
    this.setModalStatus("Creating consensus annotation...", false)
    try {
      const response = await fetch(this.exportUrlValue, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        credentials: "same-origin",
        body: JSON.stringify({
          ontology_term_type_id: this.typeSelectTarget.value,
          project_ids: this.selectedProjectIds(),
          equal_rank_choices: this.equalRankChoices,
          collision_choices: this.collisionChoices
        })
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok || payload.status !== "ok") {
        throw new Error(payload.message || "Failed to create consensus annotation")
      }
      const assigned = payload.assigned_cell_count != null ? Number(payload.assigned_cell_count).toLocaleString() : "?"
      const total = payload.total_cell_count != null ? Number(payload.total_cell_count).toLocaleString() : "?"
      let msg = `${payload.metadata_path} created. Assigned ${assigned} / ${total} cells.`
      if (payload.backed_up && payload.backup_path) {
        msg += ` Previous metadata backed up to ${payload.backup_path}.`
      }
      this.setModalStatus(msg, false)
      this.setStatus(msg, false)
      await this.reloadAnnotations()
      await this.reloadConsensusSupport()
      setTimeout(() => this.closeModal(), 1200)
    } catch (error) {
      this.setModalStatus(error.message || "Failed to create consensus annotation", true)
      this.refreshValidateEnabled()
    }
  }

  escapeHtml(value) {
    return String(value == null ? "" : value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  }

  escapeAttr(value) {
    return this.escapeHtml(value).replaceAll("`", "&#96;")
  }
}
