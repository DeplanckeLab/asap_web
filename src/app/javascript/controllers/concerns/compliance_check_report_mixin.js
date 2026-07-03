export const complianceCheckReportMixin = {
  initComplianceCheckReportState() {
    this.checkDetails = []
    this.rulesYamlLines = null
    this.rulesYamlLoadPromise = null
    this.rulesYamlHighlight = null
    this.rulesYamlPanelOpen = false
  },

  renderResult(result, { showResultBanner = true, revealResultWrap = true } = {}) {
    const errors = this.dedupeIssues(result.errors || [])
    const warnings = this.dedupeIssues(result.warnings || [])
    const valid = result.valid
    const groups = result.check_groups || []
    const issueContext = { baseWarnings: warnings, baseErrors: errors }
    const checkCounts = this.summarizeGroupedChecks(groups, issueContext)

    this.checkDetails = []
    if (revealResultWrap && this.hasResultWrapTarget) {
      this.resultWrapTarget.classList.remove("hidden")
    }

    const solutionHintHtml = !valid && typeof this.renderNonCompliantSolutionHint === "function"
      ? this.renderNonCompliantSolutionHint()
      : ""

    const bannerHtml = showResultBanner
      ? `
      <div class="mb-4 p-4 rounded border ${valid ? "border-green-300 bg-green-50" : "border-red-300 bg-red-50"}">
        <div class="font-semibold ${valid ? "text-green-800" : "text-red-800"}">
          ${valid ? "Compliant" : "Not compliant"} (${(result.format || "FILE").toString().toUpperCase()})
        </div>
        <div class="text-sm text-gray-700 mt-1">
          ${this.renderGlobalCheckSummary(errors.length, warnings.length, checkCounts)}
        </div>
        ${solutionHintHtml}
        <div class="text-xs text-gray-600 mt-2">Click a message to view rule details.</div>
      </div>`
      : `<div class="text-xs text-gray-600 mb-4">Click a message to view rule details.</div>`

    this.resultBodyTarget.innerHTML = `
      ${bannerHtml}
      ${this.renderList("Errors", errors, "red", { defaultStatus: "failed" })}
      ${this.renderList("Warnings", warnings, "yellow", { defaultStatus: "warning" })}
      ${groups.map((group) => this.renderDetailList(group.label, group.items || [], issueContext)).join("")}
    `
    this.bindCheckDetailClicks()
  },

  formatFieldValues(values) {
    if (!values || values.length === 0) return ""
    const limit = 3
    if (values.length <= limit) {
      return `<span class="text-gray-600"> — ${this.escape(values.join(", "))}</span>`
    }
    const preview = values.slice(0, limit).join(", ")
    return `<span class="text-gray-600"> — ${this.escape(preview)} (+${values.length - limit} more)</span>`
  },

  registerCheckDetail(detail, sourceItem, resolveOptions = {}) {
    if (!detail || typeof detail !== "object") return null
    const status = this.resolveCheckStatus(sourceItem || {}, resolveOptions)
    const index = this.checkDetails.length
    this.checkDetails.push({ ...detail, status })
    return index
  },

  bindCheckDetailClicks() {
    this.resultBodyTarget.querySelectorAll("[data-check-detail-index]").forEach((element) => {
      element.addEventListener("click", (event) => {
        const index = Number(event.currentTarget.dataset.checkDetailIndex)
        this.showCheckDetail(index)
      })
    })
  },

  showCheckDetail(index) {
    const detail = this.checkDetails[index]
    if (!detail || !this.hasDetailModalTarget) return

    this.updateDetailHeader(detail)
    this.detailBodyTarget.innerHTML = this.renderCheckDetailBody(detail)
    this.foldRulesYamlPanel()
    this.bindRulesYamlInteractions(detail)
    this.detailModalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  },

  closeCheckDetail(event) {
    if (event) event.preventDefault()
    if (!this.hasDetailModalTarget) return
    this.detailModalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    this.clearDetailHeader()
    this.foldRulesYamlPanel()
    this.rulesYamlHighlight = null
  },

  checkStatusPalette() {
    return {
      passed: { badge: "bg-green-100 text-green-800", label: "Passed", code: "bg-green-100" },
      warning: { badge: "bg-yellow-100 text-yellow-800", label: "Warning", code: "bg-yellow-100" },
      failed: { badge: "bg-red-100 text-red-800", label: "Error", code: "bg-red-100" },
      skipped: { badge: "bg-gray-100 text-gray-700", label: "Not applicable", code: "bg-gray-100" }
    }
  },

  renderCheckStatusBadge(statusKey) {
    const st = this.checkStatusPalette()[statusKey] || this.checkStatusPalette().passed
    return `<span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${st.badge}">${st.label}</span>`
  },

  updateDetailHeader(detail) {
    this.detailTitleTarget.textContent = detail.title || detail.field || "Rule details"
    if (!this.hasDetailStatusBadgeTarget) return

    const statusKey = this.resolveCheckStatus(detail, {})
    this.detailStatusBadgeTarget.innerHTML = this.renderCheckStatusBadge(statusKey)
    this.detailStatusBadgeTarget.classList.remove("hidden")
  },

  clearDetailHeader() {
    if (!this.hasDetailStatusBadgeTarget) return
    this.detailStatusBadgeTarget.innerHTML = ""
    this.detailStatusBadgeTarget.classList.add("hidden")
  },

  closeCheckDetailOnBackdrop(event) {
    if (event.target === this.detailModalTarget) {
      this.closeCheckDetail(event)
    }
  },

  closeCheckDetailOnEscape(event) {
    if (event.key === "Escape" && this.hasDetailModalTarget && !this.detailModalTarget.classList.contains("hidden")) {
      this.closeCheckDetail(event)
    }
  },

  stopCheckDetailPanelClick(event) {
    event.stopPropagation()
  },

  renderCheckDetailBody(detail) {
    const rows = []
    const showRulesBadge = this.detailHasRulesYaml(detail)

    if (detail.category_label) {
      rows.push(`<div><span class="font-medium text-gray-900">Category:</span> ${this.escape(detail.category_label)}</div>`)
    }
    if (detail.field) {
      rows.push(`<div><span class="font-medium text-gray-900">Field:</span> <code class="px-1 rounded bg-slate-100">${this.escape(detail.field)}</code></div>`)
    }
    if (detail.summary) {
      rows.push(`<div class="mt-3"><span class="font-medium text-gray-900">Rule:</span> ${this.escape(detail.summary)}</div>`)
    }

    const constraints = Array.isArray(detail.constraints) ? detail.constraints : []
    const checksPerformed = this.normalizeChecksPerformed(detail.checks_performed)
    const rulesBadge = showRulesBadge ? this.rulesYamlBadgeHtml() : ""

    if (checksPerformed.length > 0 && constraints.length === 0) {
      const checkLines = checksPerformed.map((check) => this.renderCheckLine(check)).join("")
      rows.push(
        `<div class="mt-3">` +
        `<div class="font-medium text-gray-900 mb-1 flex items-center gap-2">Checks performed${rulesBadge}</div>` +
        `<ul class="list-disc pl-5 space-y-1 text-sm">${checkLines}</ul>` +
        `</div>`
      )
    }

    if (constraints.length > 0) {
      const constraintLines = constraints.map((row) => this.renderConstraintLine(row)).join("")
      rows.push(
        `<div class="mt-3">` +
        `<div class="font-medium text-gray-900 mb-1 flex items-center gap-2">Constraints${rulesBadge}</div>` +
        `<ul class="list-disc pl-5 space-y-1">${constraintLines}</ul>` +
        `</div>`
      )
    }

    if (detail.result_message) {
      rows.push(`<div class="mt-3"><span class="font-medium text-gray-900">Result:</span> ${this.escape(detail.result_message)}</div>`)
    }

    if (detail.schema_version) {
      rows.push(`<div class="mt-3 text-sm text-gray-600">Reference schema version: ${this.escape(detail.schema_version)}</div>`)
    }

    if (detail.schema_url) {
      const url = this.escape(detail.schema_url)
      rows.push(`<div class="mt-3"><a href="${url}" target="_blank" rel="noopener noreferrer" class="text-blue-700 hover:underline">Open scFAIR schema documentation</a></div>`)
    }

    return rows.join("")
  },

  detailHasRulesYaml(detail) {
    const constraints = Array.isArray(detail.constraints) ? detail.constraints : []
    if (constraints.some((row) => row.from_rules === true || row["from_rules"] === true)) return true

    return this.normalizeChecksPerformed(detail.checks_performed).some((check) => check.rules_path)
  },

  normalizeChecksPerformed(checks) {
    return (Array.isArray(checks) ? checks : []).map((check) => {
      if (typeof check === "string") {
        return { text: check, rules_path: null }
      }
      return {
        text: (check.text || check["text"] || "").toString(),
        rules_path: check.rules_path || check["rules_path"] || null
      }
    })
  },

  rulesYamlBadgeHtml() {
    return (
      `<button type="button" data-rules-yaml-badge ` +
      `class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-emerald-50 text-emerald-800 border border-emerald-200 hover:bg-emerald-100 cursor-pointer" ` +
      `title="Show rules.yaml">rules.yaml</button>`
    )
  },

  renderCheckLine(check) {
    const text = this.escape(check.text)
    if (!check.rules_path) {
      return `<li>${text}</li>`
    }
    return (
      `<li class="cursor-pointer hover:bg-emerald-50 rounded -mx-1 px-1" data-rules-path="${this.escape(check.rules_path)}" ` +
      `title="Highlight in rules.yaml: ${this.escape(check.rules_path)}">${text}</li>`
    )
  },

  renderConstraintLine(row) {
    const label = this.escape(row.label || row["label"] || "")
    const value = this.escape(row.value || row["value"] || "")
    const rulesPath = row.rules_path || row["rules_path"] || ""
    const fromRules = (row.from_rules === true || row["from_rules"] === true) && rulesPath
    const fromFile = row.from_file === true || row["from_file"] === true
    if (fromFile) {
      const docClick = rulesPath
        ? ` class="cursor-pointer hover:bg-slate-50 rounded -mx-1 px-1" data-rules-path="${this.escape(rulesPath)}" title="Documentation in rules.yaml: ${this.escape(rulesPath)}"`
        : ""
      return (
        `<li${docClick}>` +
        `<span class="font-medium">${label}:</span> ${value}` +
        `<span class="text-xs text-gray-500 ml-1">(from this file)</span>` +
        `</li>`
      )
    }
    if (!fromRules) {
      return `<li><span class="font-medium">${label}:</span> ${value}</li>`
    }
    return (
      `<li class="cursor-pointer hover:bg-emerald-50 rounded -mx-1 px-1" data-rules-path="${this.escape(rulesPath)}" ` +
      `title="Highlight in rules.yaml: ${this.escape(rulesPath)}">` +
      `<span class="font-medium">${label}:</span> ${value}</li>`
    )
  },

  bindRulesYamlInteractions(_detail) {
    this.detailBodyTarget.querySelectorAll("[data-rules-yaml-badge]").forEach((badge) => {
      badge.addEventListener("click", (event) => {
        event.preventDefault()
        event.stopPropagation()
        this.unfoldRulesYamlPanel()
      })
    })

    this.detailBodyTarget.querySelectorAll("[data-rules-path]").forEach((row) => {
      row.addEventListener("click", (event) => {
        event.preventDefault()
        event.stopPropagation()
        this.highlightRulesPath(row.dataset.rulesPath)
      })
    })
  },

  foldRulesYamlPanel() {
    this.setRulesYamlPanelOpen(false)
    if (this.hasDetailYamlHighlightTarget) {
      this.detailYamlHighlightTarget.classList.add("hidden")
      this.detailYamlHighlightTarget.textContent = ""
    }
    this.rulesYamlHighlight = null
    this.renderRulesYamlPanel()
  },

  async unfoldRulesYamlPanel() {
    if (!this.hasDetailYamlPanelTarget) return
    this.setRulesYamlPanelOpen(true)
    this.renderRulesYamlPanel()
    await this.ensureRulesYamlLoaded()
    this.renderRulesYamlPanel()
  },

  setRulesYamlPanelOpen(open) {
    this.rulesYamlPanelOpen = open
    if (this.hasDetailDialogTarget) {
      this.detailDialogTarget.classList.toggle("is-yaml-open", open)
    }
    if (this.hasDetailSplitTarget) {
      this.detailSplitTarget.classList.toggle("is-yaml-open", open)
    }
    if (this.hasDetailYamlPanelTarget) {
      this.detailYamlPanelTarget.setAttribute("aria-hidden", open ? "false" : "true")
    }
  },

  afterRulesYamlPanelTransition(callback) {
    const node = this.hasDetailSplitTarget ? this.detailSplitTarget : this.detailYamlPanelTarget
    if (!node) {
      callback()
      return
    }
    let completed = false
    const finish = () => {
      if (completed) return
      completed = true
      node.removeEventListener("transitionend", onTransitionEnd)
      callback()
    }
    const onTransitionEnd = (event) => {
      if (event.target === node && event.propertyName === "grid-template-columns") finish()
    }
    node.addEventListener("transitionend", onTransitionEnd)
    window.setTimeout(finish, 320)
  },

  async highlightRulesPath(path) {
    if (!path) return
    await this.unfoldRulesYamlPanel()

    try {
      const payload = await this.fetchRulesSnippet(path)
      this.rulesYamlHighlight = {
        path: payload.path || path,
        start: payload.highlight_start,
        end: payload.highlight_end
      }
      if (this.hasDetailYamlHighlightTarget) {
        this.detailYamlHighlightTarget.textContent = `Highlighted: ${this.rulesYamlHighlight.path}`
        this.detailYamlHighlightTarget.classList.remove("hidden")
      }
      this.renderRulesYamlPanel()
      this.afterRulesYamlPanelTransition(() => this.scrollRulesYamlToHighlight())
    } catch (error) {
      if (this.hasDetailYamlHighlightTarget) {
        this.detailYamlHighlightTarget.textContent = error.message || "Unable to locate rules.yaml path"
        this.detailYamlHighlightTarget.classList.remove("hidden")
      }
    }
  },

  async ensureRulesYamlLoaded() {
    if (this.rulesYamlLines) return this.rulesYamlLines
    if (this.rulesYamlLoadPromise) return this.rulesYamlLoadPromise

    this.rulesYamlLoadPromise = this.fetchRulesYaml().then((payload) => {
      this.rulesYamlLines = Array.isArray(payload.lines) ? payload.lines : []
      return this.rulesYamlLines
    }).finally(() => {
      this.rulesYamlLoadPromise = null
    })

    return this.rulesYamlLoadPromise
  },

  async fetchRulesYaml() {
    const baseUrl = this.rulesYamlUrlValue || "/compliance/rules_yaml"
    const schemaId = this.resolveSchemaId()
    const url = schemaId ? `${baseUrl}?schema_id=${encodeURIComponent(schemaId)}` : baseUrl
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    const payload = await response.json()
    if (!response.ok) {
      throw new Error(payload.error || "Unable to load rules.yaml")
    }
    return payload
  },

  async fetchRulesSnippet(path) {
    const baseUrl = this.rulesSnippetUrlValue || "/compliance/rules_snippet"
    const schemaId = this.resolveSchemaId()
    const params = new URLSearchParams({ path })
    if (schemaId) params.set("schema_id", schemaId)
    const url = `${baseUrl}?${params.toString()}`
    const response = await fetch(url, { headers: { Accept: "application/json" } })
    const payload = await response.json()
    if (!response.ok) {
      throw new Error(payload.error || "Snippet not found")
    }
    return payload
  },

  renderRulesYamlPanel() {
    if (!this.hasDetailYamlContentTarget) return

    if (!this.rulesYamlLines) {
      this.detailYamlContentTarget.innerHTML = `<div class="text-gray-500 p-2">Loading rules.yaml...</div>`
      return
    }

    const highlight = this.rulesYamlHighlight
    const lineRows = this.rulesYamlLines.map((line) => {
      const lineNumber = line.number
      const text = this.escape(line.text || "")
      const isHighlight = highlight &&
        lineNumber >= highlight.start &&
        lineNumber <= highlight.end
      const rowClass = isHighlight
        ? "bg-emerald-100 border-l-2 border-emerald-500"
        : "border-l-2 border-transparent"
      const dimClass = highlight && !isHighlight ? " text-gray-400" : ""
      return (
        `<div class="flex ${rowClass}${dimClass}" data-rules-yaml-line="${lineNumber}">` +
        `<span class="select-none shrink-0 w-10 pr-2 text-right text-gray-400">${lineNumber}</span>` +
        `<code class="flex-1 whitespace-pre-wrap break-all">${text}</code>` +
        `</div>`
      )
    }).join("")

    this.detailYamlContentTarget.innerHTML = lineRows
  },

  scrollRulesYamlToHighlight() {
    if (!this.hasDetailYamlContentTarget || !this.rulesYamlHighlight) return
    const firstLine = this.detailYamlContentTarget.querySelector(
      `[data-rules-yaml-line="${this.rulesYamlHighlight.start}"]`
    )
    if (firstLine) {
      firstLine.scrollIntoView({ block: "center" })
    }
  },

  resolveCheckStatus(item, { defaultStatus = null, baseWarnings = [], baseErrors = [] } = {}) {
    const explicit = String(item?.status || "").trim().toLowerCase()
    if (explicit) return explicit

    const field = String(item?.field || "")
    if (field && baseWarnings.some((w) => w.field === field)) return "warning"
    if (field && baseErrors.some((e) => e.field === field)) return "failed"
    if (defaultStatus) return defaultStatus

    return "passed"
  },

  dedupeIssues(items) {
    const seen = new Set()
    return items.filter((it) => {
      const key = `${it.field || ""}|${it.message || ""}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
  },

  summarizeGroupedChecks(groups, issueContext = {}) {
    const counts = { passed: 0, skipped: 0, failed: 0, warning: 0 }
    groups.forEach((group) => {
      (group.items || []).forEach((item) => {
        const status = this.resolveCheckStatus(item, issueContext)
        if (Object.prototype.hasOwnProperty.call(counts, status)) counts[status] += 1
      })
    })
    return counts
  },

  renderGlobalCheckSummary(errorCount, warningCount, checkCounts) {
    const parts = []
    if (errorCount > 0) {
      parts.push(this.renderSummaryCountBadge(errorCount, "error(s)", "bg-red-100 text-red-800"))
    }
    if (warningCount > 0) {
      parts.push(this.renderSummaryCountBadge(warningCount, "warning(s)", "bg-yellow-100 text-yellow-800"))
    }
    if (checkCounts.passed > 0) {
      parts.push(this.renderSummaryCountBadge(checkCounts.passed, "passed", "bg-green-100 text-green-800"))
    }
    if (checkCounts.skipped > 0) {
      parts.push(this.renderSummaryCountBadge(checkCounts.skipped, "not applicable", "bg-gray-100 text-gray-700"))
    }
    if (parts.length === 0) return ""
    return `<span class="inline-flex flex-wrap items-center gap-2">${parts.join("")}</span>`
  },

  renderSummaryCountBadge(count, label, colorClass) {
    return `<span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${colorClass}">${count} ${label}</span>`
  },

  renderDetailList(title, items, context = {}) {
    if (!items || items.length === 0) return ""
    return this.renderList(title, items, "detail", context)
  },

  renderList(title, items, color, context = {}) {
    if (!items || items.length === 0) return ""
    const defaultStatus = color === "yellow" ? "warning" : color === "red" ? "failed" : null
    const resolveOptions = { defaultStatus, ...context }
    const palette = {
      red: { code: "bg-red-100", box: "border-red-200 bg-red-50" },
      yellow: { code: "bg-yellow-100", box: "border-yellow-200 bg-yellow-50" },
      green: { code: "bg-green-100", box: "border-green-200 bg-green-50" },
      detail: { code: "bg-slate-100", box: "border-slate-200 bg-slate-50" }
    }
    const statusPalette = this.checkStatusPalette()
    const style = palette[color] || palette.detail
    const failedCount = items.filter((it) => this.resolveCheckStatus(it, resolveOptions) === "failed").length
    const warningCount = items.filter((it) => this.resolveCheckStatus(it, resolveOptions) === "warning").length
    const summaryParts = []
    if (failedCount > 0) summaryParts.push(`${failedCount} failed`)
    if (warningCount > 0) summaryParts.push(`${warningCount} warning(s)`)
    const summary = summaryParts.length > 0 ? ` - ${summaryParts.join(", ")}` : ""
    const lines = items.map((it) => {
      const field = this.escape(it.field || "-")
      const msg = this.escape(it.message || "")
      const valueText = this.formatFieldValues(it.values || it["values"])
      const statusKey = this.resolveCheckStatus(it, resolveOptions)
      const st = statusPalette[statusKey] || statusPalette.passed
      const codeClass = st.code
      const listLabel = statusKey === "failed" ? "Failed" : st.label
      const badge = `<span class="ml-2 px-1.5 py-0.5 rounded text-xs ${st.badge}">${listLabel}</span>`
      const detailIndex = this.registerCheckDetail(it.detail, it, resolveOptions)
      const clickable = detailIndex !== null ? " cursor-pointer hover:bg-white/70 rounded px-1 -mx-1" : ""
      const detailAttr = detailIndex !== null
        ? ` data-check-detail-index="${detailIndex}" title="Show rule details"`
        : ""
      return `<li class="text-sm${clickable}"${detailAttr}><code class="px-1 rounded ${codeClass}">${field}</code>${badge} ${msg}${valueText}</li>`
    }).join("")
    return `
      <div class="mb-4 p-3 rounded border ${style.box}">
        <div class="font-medium mb-2">${title} (${items.length})${summary}</div>
        <ul class="space-y-1">${lines}</ul>
      </div>
    `
  },

  escape(value) {
    return String(value ?? "").replace(/[&<>"']/g, (m) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[m]
    ))
  },

  resolveSchemaId() {
    if (this.hasSchemaIdValue && this.schemaIdValue) {
      return this.schemaIdValue
    }
    if (this.hasSchemaSelectTarget && this.schemaSelectTarget.value) {
      return this.schemaSelectTarget.value
    }
    return null
  }
}
