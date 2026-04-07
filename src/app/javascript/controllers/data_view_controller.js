import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["content", "loading"]
  static values = {
    projectId: String
  }

  connect() {
    console.log('[DataViewController] Connected')
    this.delimiterValues = ["\n", "\t", " ", ";", ","]
    this.setupModalListeners()
    this.cleanUrlParams()
  }

  cleanUrlParams() {
    const url = new URL(window.location.href)
    const keysToRemove = ['loom_file', 'data_type']
    keysToRemove.forEach(k => url.searchParams.delete(k))
    window.history.replaceState({}, '', url.toString())
  }

  setupModalListeners() {
    this.element.querySelectorAll('.metadata-type-btn').forEach(btn => {
      btn.addEventListener('click', (e) => this.selectMetadataType(e))
    })
    this.element.querySelectorAll('.input-type-btn').forEach(btn => {
      btn.addEventListener('click', (e) => this.selectInputType(e))
    })
    this.element.querySelectorAll('.input-method-btn').forEach(btn => {
      btn.addEventListener('click', (e) => this.selectInputMethod(e))
    })

    const nameInput = this.element.querySelector('#import-metadata-name')
    if (nameInput) nameInput.addEventListener('input', () => this.checkForm())

    const contentInput = this.element.querySelector('#import-metadata-content')
    if (contentInput) {
      contentInput.addEventListener('input', () => this.checkForm())
      contentInput.addEventListener('keydown', (e) => {
        if (e.key === 'Tab') {
          e.preventDefault()
          var start = contentInput.selectionStart
          var end = contentInput.selectionEnd
          contentInput.value = contentInput.value.substring(0, start) + '\t' + contentInput.value.substring(end)
          contentInput.setSelectionRange(start + 1, start + 1)
        }
      })
    }

    const delimiterSelect = this.element.querySelector('#import-delimiter')
    if (delimiterSelect) delimiterSelect.addEventListener('change', () => this.updatePlaceholder())

    const fileInput = this.element.querySelector('#import-metadata-file')
    if (fileInput) {
      fileInput.addEventListener('change', (e) => this.handleFileSelect(e))
    }

    this.element.addEventListener('change', (e) => {
      if (!e.target.matches || !e.target.matches('input.import-collision-radio')) return
      const warnings = this.element.querySelector('#import-warnings')
      const sel = warnings && warnings.querySelector('input.import-collision-radio:checked')
      window._importCollisionResolution = sel ? sel.value : ''
      this.updateImportSubmitEnabled()
    })

    this.element.querySelectorAll('.import-cross-mode-radio').forEach((r) => {
      r.addEventListener('change', () => this.toggleImportCrossMode())
    })

    const discoverA = this.element.querySelector('#import-cross-discover-a-btn')
    if (discoverA) discoverA.addEventListener('click', () => this.discoverMetadataImportModeA())

    const discoverB = this.element.querySelector('#import-cross-discover-b-btn')
    if (discoverB) discoverB.addEventListener('click', () => this.discoverMetadataImportModeB())

    const fromProjectSection = this.element.querySelector('#import-from-project-section')
    if (fromProjectSection) {
      fromProjectSection.addEventListener('click', (e) => {
        const btn = e.target.closest('button.import-cross-annot-btn')
        if (!btn || btn.disabled) return
        const sp = parseInt(btn.getAttribute('data-source-project-id'), 10)
        const aid = parseInt(btn.getAttribute('data-source-annot-id'), 10)
        const aname = btn.dataset.annotName || ''
        if (sp > 0 && aid > 0) this.pickCrossProjectAnnot(sp, aid, aname)
      })
    }
  }

  getProjectIdentifier() {
    if (this.projectIdValue) {
      return this.projectIdValue
    }
    const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
    return pathMatch ? pathMatch[1] : null
  }

  addMetadata(event) {
    const modal = this.element.querySelector('#add-metadata-modal')
    if (modal) {
      this.resetModal()
      modal.classList.remove('hidden')
      this.fetchSampleIdentifiers()
    }
  }

  fetchSampleIdentifiers() {
    const projectId = this.getProjectIdentifier()
    const loomFile = new URLSearchParams(window.location.search).get('loom_file') || ''
    if (!loomFile) return

    fetch(`/projects/${projectId}/sample_identifiers?loom_file=${encodeURIComponent(loomFile)}`, {
      headers: { 'Accept': 'application/json' },
      credentials: 'same-origin'
    })
      .then(r => r.ok ? r.json() : { cells: [], genes: [] })
      .then(data => {
        this.sampleCells = data.cells || []
        this.sampleGenes = data.genes || []
        this.updatePlaceholder()
      })
      .catch(() => {
        this.sampleCells = []
        this.sampleGenes = []
      })
  }

  resetModal() {
    const metadataTypeId = this.element.querySelector('#import-metadata-type-id')
    const inputTypeId = this.element.querySelector('#import-input-type-id')
    const inputMethodId = this.element.querySelector('#import-input-method-id')
    if (metadataTypeId) metadataTypeId.value = '1'
    if (inputTypeId) inputTypeId.value = '1'
    if (inputMethodId) inputMethodId.value = '1'

    this.activateButton('.metadata-type-btn', '1', 'data-metadata-type')
    this.activateButton('.input-type-btn', '1', 'data-input-type')
    this.activateButton('.input-method-btn', '1', 'data-input-method')

    const name = this.element.querySelector('#import-metadata-name')
    if (name) { name.value = ''; name.disabled = false; name.placeholder = 'Metadata name (as written in Loom file)' }

    const content = this.element.querySelector('#import-metadata-content')
    if (content) content.value = ''

    const fileInput = this.element.querySelector('#import-metadata-file')
    if (fileInput) fileInput.value = ''

    const fileInfo = this.element.querySelector('#import-file-info')
    if (fileInfo) { fileInfo.classList.add('hidden'); fileInfo.textContent = '' }

    const hasHeader = this.element.querySelector('#import-has-header')
    if (hasHeader) { hasHeader.checked = true; hasHeader.disabled = false }

    this.element.querySelector('#import-copypaste-section')?.classList.remove('hidden')
    this.element.querySelector('#import-upload-section')?.classList.add('hidden')
    this.element.querySelector('#import-delimiter-group')?.classList.remove('hidden')
    this.element.querySelector('#import-name-group')?.classList.remove('hidden')
    this.element.querySelector('#import-has-header-group')?.classList.remove('hidden')
    this.element.querySelector('#import-format-group')?.classList.remove('hidden')
    this.element.querySelector('#import-format-desc-list')?.classList.remove('hidden')
    this.element.querySelector('#import-format-desc-matrix')?.classList.add('hidden')
    this.element.querySelector('#import-format-desc-global')?.classList.add('hidden')

    const previewBtn = this.element.querySelector('#import-preview-btn')
    if (previewBtn) { previewBtn.disabled = true; previewBtn.classList.remove('hidden') }

    const submitBtn = this.element.querySelector('#import-submit-btn')
    if (submitBtn) { submitBtn.disabled = true; submitBtn.classList.add('hidden') }

    const warnings = this.element.querySelector('#import-warnings')
    if (warnings) { warnings.classList.add('hidden'); warnings.innerHTML = '' }

    const preview = this.element.querySelector('#import-preview')
    if (preview) preview.classList.add('hidden')

    this.element.querySelector('#import-from-project-section')?.classList.add('hidden')
    const crossStatus = this.element.querySelector('#import-cross-status')
    if (crossStatus) { crossStatus.classList.add('hidden'); crossStatus.textContent = '' }
    const crossSel = this.element.querySelector('#import-cross-selection')
    if (crossSel) { crossSel.classList.add('hidden'); crossSel.textContent = '' }
    this.element.querySelector('#import-cross-sources')?.replaceChildren()
    this.element.querySelector('#import-cross-annots-flat')?.replaceChildren()
    const crossKey = this.element.querySelector('#import-cross-source-project-key')
    if (crossKey) crossKey.value = ''
    const modeA = this.element.querySelector('#import-cross-mode-a')
    const modeB = this.element.querySelector('#import-cross-mode-b')
    if (modeA) modeA.classList.remove('hidden')
    if (modeB) modeB.classList.add('hidden')
    this.element.querySelectorAll('.import-cross-mode-radio').forEach((r) => {
      r.checked = r.value === 'a'
    })

    this.crossProjectSelection = null
    this.crossProjectPrepareMeta = null
    this.fuId = null
    this.lastImportValidation = null
    window._importCollisionResolution = ''
    this.updatePlaceholder()
  }

  activateButton(selector, value, attr) {
    this.element.querySelectorAll(selector).forEach(btn => {
      if (btn.getAttribute(attr) === value) {
        btn.classList.remove('bg-gray-100', 'text-gray-700', 'hover:bg-gray-200')
        btn.classList.add('bg-blue-600', 'text-white')
      } else {
        btn.classList.remove('bg-blue-600', 'text-white')
        btn.classList.add('bg-gray-100', 'text-gray-700', 'hover:bg-gray-200')
      }
    })
  }

  selectMetadataType(event) {
    const type = event.currentTarget.getAttribute('data-metadata-type')
    this.element.querySelector('#import-metadata-type-id').value = type
    this.activateButton('.metadata-type-btn', type, 'data-metadata-type')

    const delimiterGroup = this.element.querySelector('#import-delimiter-group')
    const nameGroup = this.element.querySelector('#import-name-group')
    const hasHeaderGroup = this.element.querySelector('#import-has-header-group')
    const descGlobal = this.element.querySelector('#import-format-desc-global')
    const descList = this.element.querySelector('#import-format-desc-list')
    const descMatrix = this.element.querySelector('#import-format-desc-matrix')

    const formatGroup = this.element.querySelector('#import-format-group')

    if (type === '4') {
      const methodNow = this.element.querySelector('#import-input-method-id')?.value
      if (methodNow === '3') {
        const b = this.element.querySelector('.input-method-btn[data-input-method="1"]')
        if (b) b.click()
      }
      if (delimiterGroup) delimiterGroup.classList.add('hidden')
      if (hasHeaderGroup) hasHeaderGroup.classList.add('hidden')
      if (formatGroup) formatGroup.classList.add('hidden')
      if (nameGroup) nameGroup.classList.remove('hidden')
      if (descGlobal) descGlobal.classList.remove('hidden')
      if (descList) descList.classList.add('hidden')
      if (descMatrix) descMatrix.classList.add('hidden')
    } else {
      if (delimiterGroup) delimiterGroup.classList.remove('hidden')
      if (hasHeaderGroup) hasHeaderGroup.classList.remove('hidden')
      if (formatGroup) formatGroup.classList.remove('hidden')
      if (nameGroup) nameGroup.classList.remove('hidden')
      if (descGlobal) descGlobal.classList.add('hidden')
      this.updateFormatDescription()
    }

    this.element.querySelectorAll('.input-method-btn[data-input-method="3"]').forEach((b) => {
      if (type === '4') {
        b.classList.add('opacity-50', 'cursor-not-allowed')
        b.setAttribute('disabled', 'disabled')
      } else {
        b.classList.remove('opacity-50', 'cursor-not-allowed')
        b.removeAttribute('disabled')
      }
    })

    this.updatePlaceholder()
    this.checkForm()
  }

  updateFormatDescription() {
    const inputType = this.element.querySelector('#import-input-type-id')?.value
    const descList = this.element.querySelector('#import-format-desc-list')
    const descMatrix = this.element.querySelector('#import-format-desc-matrix')
    if (inputType === '2') {
      if (descList) descList.classList.add('hidden')
      if (descMatrix) descMatrix.classList.remove('hidden')
    } else {
      if (descList) descList.classList.remove('hidden')
      if (descMatrix) descMatrix.classList.add('hidden')
    }
  }

  selectInputType(event) {
    const type = event.currentTarget.getAttribute('data-input-type')
    this.element.querySelector('#import-input-type-id').value = type
    this.activateButton('.input-type-btn', type, 'data-input-type')

    const delimiter = this.element.querySelector('#import-delimiter')
    const name = this.element.querySelector('#import-metadata-name')
    const hasHeader = this.element.querySelector('#import-has-header')
    if (type === '2') {
      if (delimiter) { delimiter.value = '0'; delimiter.disabled = true }
      if (name) { name.disabled = true; name.placeholder = 'Metadata names have to be set in the header of the file' }
      if (hasHeader) { hasHeader.checked = true; hasHeader.disabled = true }
    } else {
      if (delimiter) { delimiter.value = '0'; delimiter.disabled = false }
      if (name) { name.disabled = false; name.placeholder = 'Metadata name (as written in Loom file)' }
      if (hasHeader) { hasHeader.disabled = false }
    }
    this.updateFormatDescription()
    this.updatePlaceholder()
    this.checkForm()
  }

  selectInputMethod(event) {
    const method = event.currentTarget.getAttribute('data-input-method')
    this.element.querySelector('#import-input-method-id').value = method
    this.activateButton('.input-method-btn', method, 'data-input-method')

    const copypaste = this.element.querySelector('#import-copypaste-section')
    const upload = this.element.querySelector('#import-upload-section')
    const fromProject = this.element.querySelector('#import-from-project-section')
    if (method === '1') {
      copypaste?.classList.remove('hidden')
      upload?.classList.add('hidden')
      fromProject?.classList.add('hidden')
    } else if (method === '2') {
      copypaste?.classList.add('hidden')
      upload?.classList.remove('hidden')
      fromProject?.classList.add('hidden')
    } else if (method === '3') {
      copypaste?.classList.add('hidden')
      upload?.classList.add('hidden')
      fromProject?.classList.remove('hidden')
      this.loadImportCellSets()
      this.applyMatrixModeForCrossProject()
    }
    this.checkForm()
  }

  toggleImportCrossMode() {
    const modal = this.element.querySelector('#add-metadata-modal')
    if (!modal) return
    const v = modal.querySelector('input.import-cross-mode-radio:checked')?.value || 'a'
    modal.querySelector('#import-cross-mode-a')?.classList.toggle('hidden', v !== 'a')
    modal.querySelector('#import-cross-mode-b')?.classList.toggle('hidden', v !== 'b')
    this.crossProjectSelection = null
    this.crossProjectPrepareMeta = null
    modal.querySelector('#import-cross-sources')?.replaceChildren()
    modal.querySelector('#import-cross-annots-flat')?.replaceChildren()
    modal.querySelector('#import-cross-selection')?.classList.add('hidden')
    this.checkForm()
  }

  applyMatrixModeForCrossProject() {
    this.element.querySelector('#import-input-type-id').value = '2'
    this.activateButton('.input-type-btn', '2', 'data-input-type')
    const delimiter = this.element.querySelector('#import-delimiter')
    const name = this.element.querySelector('#import-metadata-name')
    const hasHeader = this.element.querySelector('#import-has-header')
    if (delimiter) { delimiter.value = '0'; delimiter.disabled = true }
    if (name) { name.disabled = true; name.placeholder = 'Set by column choice' }
    if (hasHeader) { hasHeader.checked = true; hasHeader.disabled = true }
    this.updateFormatDescription()
  }

  loadImportCellSets() {
    const projectId = this.getProjectIdentifier()
    const sel = this.element.querySelector('#import-cross-cell-set-id')
    const status = this.element.querySelector('#import-cross-status')
    if (!projectId || !sel) return

    fetch(`/projects/${projectId}/metadata_import_cell_sets`, {
      headers: { Accept: 'application/json' },
      credentials: 'same-origin'
    })
      .then((r) => r.json())
      .then((data) => {
        if (status) {
          status.classList.toggle('hidden', !data.error)
          status.textContent = data.error || ''
        }
        const rows = data.cell_sets || []
        if (!rows.length) {
          sel.innerHTML = '<option value="">No cell sets</option>'
          return
        }
        sel.innerHTML = rows.map((cs) =>
          `<option value="${cs.id}">${this.escapeHtml(cs.key)}</option>`
        ).join('')
      })
      .catch(() => {
        sel.innerHTML = '<option value="">Failed to load</option>'
      })
  }

  discoverMetadataImportModeA() {
    const projectId = this.getProjectIdentifier()
    const csId = this.element.querySelector('#import-cross-cell-set-id')?.value
    const box = this.element.querySelector('#import-cross-sources')
    const status = this.element.querySelector('#import-cross-status')
    if (!projectId || !csId) {
      if (status) {
        status.textContent = 'Choose a cell set first.'
        status.classList.remove('hidden')
      }
      return
    }
    if (status) status.classList.add('hidden')
    if (box) box.innerHTML = 'Loading...'
    this.crossProjectSelection = null
    this.crossProjectPrepareMeta = null
    this.element.querySelector('#import-cross-selection')?.classList.add('hidden')

    fetch(`/projects/${projectId}/discover_metadata_import_sources?cell_set_id=${encodeURIComponent(csId)}`, {
      headers: { Accept: 'application/json' },
      credentials: 'same-origin'
    })
      .then((r) => r.json().then((j) => ({ ok: r.ok, j })))
      .then(({ ok, j }) => {
        if (!ok) {
          if (box) box.innerHTML = ''
          if (status) {
            status.textContent = j.error || 'Discovery failed'
            status.classList.remove('hidden')
          }
          return
        }
        const sources = j.sources || []
        if (!sources.length) {
          if (box) box.innerHTML = '<p class="text-gray-600">No other readable projects with metadata on this cell set.</p>'
          return
        }
        if (box) {
          box.innerHTML = sources.map((src) => this.renderCrossProjectSourceBlock(src)).join('')
        }
      })
      .catch((err) => {
        if (box) box.innerHTML = ''
        if (status) {
          status.textContent = err.message || 'Request failed'
          status.classList.remove('hidden')
        }
      })
  }

  discoverMetadataImportModeB() {
    const projectId = this.getProjectIdentifier()
    const key = this.element.querySelector('#import-cross-source-project-key')?.value?.trim()
    const box = this.element.querySelector('#import-cross-annots-flat')
    const status = this.element.querySelector('#import-cross-status')
    if (!projectId || !key) {
      if (status) {
        status.textContent = 'Enter a source project key.'
        status.classList.remove('hidden')
      }
      return
    }
    if (status) status.classList.add('hidden')
    if (box) box.innerHTML = 'Loading...'
    this.crossProjectSelection = null
    this.crossProjectPrepareMeta = null
    this.element.querySelector('#import-cross-selection')?.classList.add('hidden')

    fetch(`/projects/${projectId}/discover_metadata_import_from_project?source_project_key=${encodeURIComponent(key)}`, {
      headers: { Accept: 'application/json' },
      credentials: 'same-origin'
    })
      .then((r) => r.json().then((j) => ({ ok: r.ok, j })))
      .then(({ ok, j }) => {
        if (!ok) {
          if (box) box.innerHTML = ''
          if (status) {
            status.textContent = j.error || 'Discovery failed'
            status.classList.remove('hidden')
          }
          return
        }
        const annots = j.annots || []
        if (!annots.length) {
          if (box) box.innerHTML = '<p class="text-gray-600">No compatible columns found.</p>'
          return
        }
        if (box) {
          box.innerHTML = annots.map((a) => this.renderCrossProjectAnnotRow(a, j.source_project?.id)).join('')
        }
      })
      .catch((err) => {
        if (box) box.innerHTML = ''
        if (status) {
          status.textContent = err.message || 'Request failed'
          status.classList.remove('hidden')
        }
      })
  }

  renderCrossProjectSourceBlock(src) {
    const proj = src.project || {}
    const pid = proj.id
    const annots = src.annots || []
    const rows = annots.map((a) => this.renderCrossProjectAnnotRow(a, pid)).join('')
    return `<div class="border border-gray-200 rounded p-2 bg-white">
      <div class="font-medium text-gray-800">${this.escapeHtml(proj.name || '')} <span class="text-gray-500 font-mono text-xs">${this.escapeHtml(proj.key || '')}</span></div>
      <div class="mt-1 space-y-1">${rows}</div>
    </div>`
  }

  renderCrossProjectAnnotRow(a, sourceProjectId) {
    const ok = a.compatible && a.import_name_allowed_on_target
    const label = (a.display_name || a.name || '').toString()
    const escAttr = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
    const why = (!ok && (a.incompatibility_reason || a.import_name_block_reason))
      ? (a.incompatibility_reason || a.import_name_block_reason).toString()
      : ''
    const reason = why ? ` title="${escAttr(why)}"` : ''
    const disabled = ok ? '' : 'disabled'
    return `<div><button type="button" class="import-cross-annot-btn text-left w-full px-2 py-1 rounded border border-gray-100 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed" data-source-project-id="${sourceProjectId}" data-source-annot-id="${a.id}" data-annot-name="${escAttr(a.name || '')}" ${disabled}${reason}>${this.escapeHtml(label)}</button></div>`
  }

  pickCrossProjectAnnot(sourceProjectId, sourceAnnotId, annotName) {
    const metaType = annotName.startsWith('/row_attrs/') ? '2' : '1'
    this.element.querySelector('#import-metadata-type-id').value = metaType
    this.activateButton('.metadata-type-btn', metaType, 'data-metadata-type')
    this.crossProjectSelection = { sourceProjectId, sourceAnnotId }
    this.crossProjectPrepareMeta = null
    const selEl = this.element.querySelector('#import-cross-selection')
    if (selEl) {
      selEl.textContent = `Selected column: ${annotName} (source project ${sourceProjectId})`
      selEl.classList.remove('hidden')
    }
    this.fuId = null
    this.lastImportValidation = null
    const warnings = this.element.querySelector('#import-warnings')
    if (warnings) { warnings.classList.add('hidden'); warnings.innerHTML = '' }
    const preview = this.element.querySelector('#import-preview')
    if (preview) preview.classList.add('hidden')
    const submitBtn = this.element.querySelector('#import-submit-btn')
    if (submitBtn) submitBtn.classList.add('hidden')
    this.checkForm()
  }

  updatePlaceholder() {
    const metadataType = this.element.querySelector('#import-metadata-type-id')?.value
    const inputType = this.element.querySelector('#import-input-type-id')?.value
    const delimiterIdx = parseInt(this.element.querySelector('#import-delimiter')?.value || '0')
    const content = this.element.querySelector('#import-metadata-content')
    if (!content) return

    const cells = this.sampleCells && this.sampleCells.length > 0 ? this.sampleCells : ['Cell1', 'Cell2', 'Cell3']
    const genes = this.sampleGenes && this.sampleGenes.length > 0 ? this.sampleGenes : ['Gene1', 'Gene2', 'Gene3']

    let lines = []
    if (metadataType === '4') {
      content.placeholder = 'Any text or JSON'
      return
    } else if (inputType === '2') {
      const ids = metadataType === '2' ? genes : cells
      const headerLabel = metadataType === '2' ? 'Gene symbols/EnsemblIDs' : 'Cell names'
      lines = [headerLabel + '\tmetadata_1\tmetadata_2']
      ids.forEach((id, i) => {
        lines.push(id + '\t' + Math.round(Math.random() * 10) + '\t' + (i % 2 === 0 ? 'TypeA' : 'TypeB'))
      })
    } else {
      lines = metadataType === '2' ? genes.slice() : cells.slice()
    }
    content.placeholder = lines.join(this.delimiterValues[delimiterIdx] || '\n')
  }

  checkForm() {
    const inputMethod = this.element.querySelector('#import-input-method-id')?.value
    const previewBtn = this.element.querySelector('#import-preview-btn')
    if (!previewBtn) return

    if (inputMethod === '3') {
      const sel = this.crossProjectSelection
      previewBtn.disabled = !(sel && sel.sourceProjectId && sel.sourceAnnotId)
      return
    }

    if (inputMethod === '2') {
      const fileInput = this.element.querySelector('#import-metadata-file')
      previewBtn.disabled = !(fileInput && fileInput.files && fileInput.files.length > 0)
      return
    }

    const inputType = this.element.querySelector('#import-input-type-id')?.value
    const name = this.element.querySelector('#import-metadata-name')?.value?.trim() || ''
    const content = this.element.querySelector('#import-metadata-content')?.value?.trim() || ''

    if (inputType === '2') {
      previewBtn.disabled = content === ''
    } else {
      previewBtn.disabled = name === '' || content === ''
    }
  }

  handleFileSelect(event) {
    const file = event.target.files[0]
    const fileInfo = this.element.querySelector('#import-file-info')
    if (file && fileInfo) {
      fileInfo.textContent = `${file.name} (${(file.size / 1024).toFixed(1)} KB)`
      fileInfo.classList.remove('hidden')
    }
    this.checkForm()
  }

  previewMetadata(event) {
    const btn = event.currentTarget
    btn.disabled = true
    btn.textContent = 'Processing...'

    const inputMethod = this.element.querySelector('#import-input-method-id')?.value
    const metadataTypeId = this.element.querySelector('#import-metadata-type-id')?.value
    const inputTypeId = this.element.querySelector('#import-input-type-id')?.value
    const delimiter = this.element.querySelector('#import-delimiter')?.value
    const name = this.element.querySelector('#import-metadata-name')?.value || ''
    const hasHeader = this.element.querySelector('#import-has-header')?.checked ? '1' : '0'
    const loomFile = this.element.querySelector('#add-metadata-modal')?.closest('[data-controller="data-view"]')
      ? new URLSearchParams(window.location.search).get('loom_file') || ''
      : ''

    const projectId = this.getProjectIdentifier()
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')

    let fetchPromise

    if (inputMethod === '3') {
      const sel = this.crossProjectSelection
      if (!sel || !sel.sourceProjectId || !sel.sourceAnnotId) {
        btn.textContent = 'Preview'
        btn.disabled = false
        return
      }
      fetchPromise = fetch(`/projects/${projectId}/prepare_metadata_from_project_annot`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          Accept: 'application/json',
          'Content-Type': 'application/json'
        },
        credentials: 'same-origin',
        body: JSON.stringify({
          source_project_id: sel.sourceProjectId,
          source_annot_id: sel.sourceAnnotId
        })
      })
    } else if (inputMethod === '2') {
      const fileInput = this.element.querySelector('#import-metadata-file')
      if (!fileInput?.files?.[0]) return

      const formData = new FormData()
      formData.append('file', fileInput.files[0])
      formData.append('metadata_type_id', metadataTypeId)
      formData.append('input_type_id', inputTypeId)
      formData.append('delimiter', delimiter)
      formData.append('name', name)
      formData.append('has_header', hasHeader)
      formData.append('loom_file', loomFile)

      fetchPromise = fetch(`/projects/${projectId}/prepare_metadata`, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken, 'Accept': 'application/json' },
        credentials: 'same-origin',
        body: formData
      })
    } else {
      const content = this.element.querySelector('#import-metadata-content')?.value || ''
      fetchPromise = fetch(`/projects/${projectId}/prepare_metadata`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        },
        credentials: 'same-origin',
        body: JSON.stringify({
          metadata_type_id: metadataTypeId,
          input_type_id: inputTypeId,
          delimiter: delimiter,
          name: name,
          has_header: hasHeader,
          content: content,
          loom_file: loomFile
        })
      })
    }

    fetchPromise
      .then(async (response) => {
        const data = await response.json().catch(() => ({}))
        if (!response.ok) {
          const msg = data.error || data.message || `HTTP error ${response.status}`
          throw new Error(msg)
        }
        return data
      })
      .then(data => {
        btn.textContent = 'Preview'
        this.fuId = data.fu_id
        this.lastImportValidation = data.import_validation || null
        window._importCollisionResolution = ''
        if (inputMethod === '3' && data.metadata_type_id) {
          this.crossProjectPrepareMeta = {
            metadataTypeId: String(data.metadata_type_id),
            inputTypeId: String(data.input_type_id || '2')
          }
        } else {
          this.crossProjectPrepareMeta = null
        }

        const warnings = this.element.querySelector('#import-warnings')
        const dupBlock = (data.duplicates && data.duplicates.length > 0)
          ? `<div class="p-3 bg-yellow-50 border border-yellow-200 rounded-md text-sm text-yellow-800">${data.duplicates.length} duplicate(s) found (${data.duplicates.map((d) => this.escapeHtml(d)).join(', ')}). Only first occurrence is kept.</div>`
          : ''
        warnings.innerHTML = dupBlock + this.buildImportValidationHtml(data.import_validation)
        warnings.classList.remove('hidden')
        this.updateImportSubmitEnabled()

        const preview = this.element.querySelector('#import-preview')
        const previewContent = this.element.querySelector('#import-preview-content')
        if (data.preview_lines && data.preview_lines.length > 0) {
          previewContent.innerHTML = data.preview_lines.map(l =>
            `<div class="py-0.5 border-b border-gray-100 last:border-0 whitespace-nowrap">${this.escapeHtml(l)}</div>`
          ).join('')
          preview.classList.remove('hidden')
        }

        if (data.header_name && inputMethod !== '3') {
          const nameInput = this.element.querySelector('#import-metadata-name')
          if (nameInput && !nameInput.value.trim()) {
            nameInput.value = data.header_name
          }
        }

        const submitBtn = this.element.querySelector('#import-submit-btn')
        if (submitBtn) { submitBtn.classList.remove('hidden') }
        this.updateImportSubmitEnabled()
        btn.classList.add('hidden')
      })
      .catch(error => {
        console.error('[DataViewController] Preview error:', error)
        btn.textContent = 'Preview'
        btn.disabled = false
        const warnings = this.element.querySelector('#import-warnings')
        warnings.innerHTML = `<div class="p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-800">Error: ${error.message}</div>`
        warnings.classList.remove('hidden')
      })
  }

  submitMetadata(event) {
    const btn = event.currentTarget
    btn.disabled = true
    btn.textContent = 'Importing...'

    const projectId = this.getProjectIdentifier()
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
    const inputMethod = this.element.querySelector('#import-input-method-id')?.value
    let metadataTypeId = this.element.querySelector('#import-metadata-type-id')?.value
    const loomFile = new URLSearchParams(window.location.search).get('loom_file') || ''

    let inputTypeId = this.element.querySelector('#import-input-type-id')?.value || '1'
    if (inputMethod === '3' && this.crossProjectPrepareMeta) {
      metadataTypeId = this.crossProjectPrepareMeta.metadataTypeId
      inputTypeId = this.crossProjectPrepareMeta.inputTypeId
    }
    const name = this.element.querySelector('#import-metadata-name')?.value || ''
    const hasHeader = this.element.querySelector('#import-has-header')?.checked ? '1' : '0'
    const headerName = ''

    fetch(`/projects/${projectId}/do_import_metadata`, {
      method: 'POST',
      headers: {
        'X-CSRF-Token': csrfToken,
        'Accept': 'application/json',
        'Content-Type': 'application/json'
      },
      credentials: 'same-origin',
      body: JSON.stringify({
        fu_id: this.fuId,
        metadata_type_id: metadataTypeId,
        loom_file: loomFile,
        input_type_id: inputTypeId,
        name: name,
        header_name: headerName,
        has_header: hasHeader,
        collision_resolution: window._importCollisionResolution || ''
      })
    })
      .then(async (response) => {
        const data = await response.json().catch(() => ({}))
        if (!response.ok) {
          const msg = data.message || data.error || `HTTP error ${response.status}`
          throw new Error(msg)
        }
        return data
      })
      .then(data => {
        const modal = this.element.querySelector('#add-metadata-modal')
        if (data.status !== 'ok') {
          const msg = data.message || data.error || 'Import failed'
          const warnings = this.element.querySelector('#import-warnings')
          warnings.innerHTML = `<div class="p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-800">${this.escapeHtml(msg)}</div>`
          warnings.classList.remove('hidden')
          btn.textContent = 'Import'
          btn.disabled = false
          return
        }
        if (modal) modal.classList.add('hidden')

        if (data.status === 'ok') {
          const dataType = metadataTypeId === '1' ? 'col_attrs' : (metadataTypeId === '2' ? 'row_attrs' : 'global')
          this.loadContent(loomFile, dataType, null)
        }
      })
      .catch(error => {
        console.error('[DataViewController] Import error:', error)
        btn.textContent = 'Import'
        btn.disabled = false
        const warnings = this.element.querySelector('#import-warnings')
        warnings.innerHTML = `<div class="p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-800">Import error: ${this.escapeHtml(error.message)}</div>`
        warnings.classList.remove('hidden')
      })
  }

  buildImportValidationHtml(iv) {
    if (!iv || iv.skip_name_checks) return ''
    if (iv.error) {
      return `<div class="p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-800 mt-2">${this.escapeHtml(iv.error)}</div>`
    }
    const checks = Array.isArray(iv.checks) ? iv.checks : []
    const badAuth = checks.filter((c) => !c.authorized)
    if (badAuth.length) {
      const msgs = badAuth.map((c) => c.auth_message || 'Name not allowed').join(' ')
      return `<div class="p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-800 mt-2">${this.escapeHtml(msgs)}</div>`
    }
    const collisions = checks.filter((c) => c.collision)
    if (!collisions.length) return ''
    let h = '<div class="p-3 bg-amber-50 border border-amber-200 rounded-md text-sm text-amber-900 mt-2">'
    h += '<p class="font-semibold mb-2">Existing metadata uses the same column path:</p><ul class="list-disc pl-5 mb-3">'
    collisions.forEach((c) => {
      h += '<li><code class="text-xs">' + this.escapeHtml(c.path || '') + '</code>'
      if ((c.dependent_run_count || 0) > 0) {
        h += ` <span class="text-amber-800">(${c.dependent_run_count} pipeline runs reference it)</span>`
      }
      h += '</li>'
    })
    h += '</ul><p class="mb-2">Choose how to proceed:</p>'
    h += '<label class="flex items-center gap-2 mb-1 cursor-pointer"><input type="radio" name="import-collision-res" value="keep_both" class="import-collision-radio"> Keep both (add version suffix .vN)</label>'
    h += '<label class="flex items-center gap-2 mb-1 cursor-pointer"><input type="radio" name="import-collision-res" value="overwrite" class="import-collision-radio"> Overwrite (only when no runs reference the column)</label>'
    h += '<label class="flex items-center gap-2 cursor-pointer"><input type="radio" name="import-collision-res" value="skip" class="import-collision-radio"> Cancel import</label></div>'
    return h
  }

  updateImportSubmitEnabled() {
    const submitBtn = this.element.querySelector('#import-submit-btn')
    if (!submitBtn) return
    const iv = this.lastImportValidation
    if (!iv || iv.skip_name_checks) {
      submitBtn.disabled = false
      return
    }
    if (iv.error) {
      submitBtn.disabled = true
      return
    }
    const checks = Array.isArray(iv.checks) ? iv.checks : []
    if (checks.some((c) => !c.authorized)) {
      submitBtn.disabled = true
      return
    }
    const collisions = checks.filter((c) => c.collision)
    if (collisions.length) {
      submitBtn.disabled = !window._importCollisionResolution
      return
    }
    submitBtn.disabled = false
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  loadContent(loomFile, dataType, event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    console.log('[DataViewController] Loading content:', { loomFile, dataType })

    if (this.hasLoadingTarget) {
      this.loadingTarget.style.display = 'block'
    }
    if (this.hasContentTarget) {
      this.contentTarget.style.display = 'none'
    }

    const projectIdentifier = this.getProjectIdentifier()
    const url = `/projects/${projectIdentifier}/data_content?loom_file=${encodeURIComponent(loomFile)}&data_type=${encodeURIComponent(dataType)}`

    fetch(url, {
      method: 'GET',
      headers: {
        'Accept': 'text/html',
        'X-Requested-With': 'XMLHttpRequest'
      },
      credentials: 'same-origin'
    })
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.text()
    })
    .then(html => {
      if (this.hasContentTarget) {
        this.contentTarget.innerHTML = html
        this.contentTarget.style.display = 'block'
      }
      if (this.hasLoadingTarget) {
        this.loadingTarget.style.display = 'none'
      }

      this.updateLeftPanelSelection(loomFile)
    })
    .catch(error => {
      console.error('[DataViewController] Error loading content:', error)
      if (this.hasContentTarget) {
        this.contentTarget.innerHTML = `<div class="p-6 text-center text-red-600">Error loading content: ${error.message}</div>`
        this.contentTarget.style.display = 'block'
      }
      if (this.hasLoadingTarget) {
        this.loadingTarget.style.display = 'none'
      }
    })
  }

  selectLoomFile(event) {
    console.log('[DataViewController] selectLoomFile called', event.currentTarget)
    const loomFile = event.currentTarget.dataset.loomFile || event.currentTarget.getAttribute('data-loom-file')
    let dataType = event.currentTarget.dataset.dataType || event.currentTarget.getAttribute('data-data-type')
    
    if (!dataType) {
      const activeTab = this.element.querySelector('[data-data-view-data-type-param].bg-blue-600')
      if (activeTab) {
        dataType = activeTab.dataset.dataTypeParam || activeTab.getAttribute('data-data-view-data-type-param')
      }
    }
    
    dataType = dataType || 'matrices'
    
    console.log('[DataViewController] Extracted:', { loomFile, dataType })
    if (!loomFile) {
      console.error('[DataViewController] No loom file found in data attributes')
      return
    }
    this.loadContent(loomFile, dataType, event)
  }

  selectDataType(event) {
    console.log('[DataViewController] selectDataType called', event.currentTarget)
    const dataType = event.currentTarget.dataset.dataTypeParam || event.currentTarget.getAttribute('data-data-view-data-type-param')
    const loomFile = event.currentTarget.dataset.loomFileParam || event.currentTarget.getAttribute('data-data-view-loom-file-param')
    console.log('[DataViewController] Extracted:', { loomFile, dataType })
    if (!loomFile || !dataType) {
      console.error('[DataViewController] Missing loom file or data type', { loomFile, dataType })
      return
    }
    this.loadContent(loomFile, dataType, event)
  }

  updateLeftPanelSelection(selectedLoomFile) {
    const leftPanelItems = this.element.querySelectorAll('[data-loom-file]')
    leftPanelItems.forEach(item => {
      const itemLoomFile = item.dataset.loomFile || item.getAttribute('data-loom-file')
      const isSelected = itemLoomFile === selectedLoomFile
      
      if (isSelected) {
        item.classList.remove('bg-white', 'hover:bg-gray-50')
        item.classList.add('bg-blue-50')
        item.style.borderLeft = '4px solid #007bff'
        const strong = item.querySelector('strong')
        if (strong) {
          strong.classList.remove('text-gray-900')
          strong.classList.add('text-blue-900')
        }
      } else {
        item.classList.remove('bg-blue-50')
        item.classList.add('bg-white', 'hover:bg-gray-50')
        item.style.borderLeft = '4px solid transparent'
        const strong = item.querySelector('strong')
        if (strong) {
          strong.classList.remove('text-blue-900')
          strong.classList.add('text-gray-900')
        }
      }
    })

    const mobileDropdownItems = this.element.querySelectorAll('[data-dropdown-target="menu"] [data-loom-file]')
    mobileDropdownItems.forEach(item => {
      const itemLoomFile = item.dataset.loomFile || item.getAttribute('data-loom-file')
      const isSelected = itemLoomFile === selectedLoomFile
      
      if (isSelected) {
        item.classList.remove('bg-white', 'hover:bg-gray-50')
        item.classList.add('bg-blue-50')
        item.style.borderLeft = '4px solid #007bff !important'
        const span = item.querySelector('span')
        if (span) {
          span.classList.remove('text-gray-900')
          span.classList.add('text-blue-900', 'font-semibold')
        }
      } else {
        item.classList.remove('bg-blue-50')
        item.classList.add('bg-white', 'hover:bg-gray-50')
        item.style.borderLeft = '4px solid transparent'
        const span = item.querySelector('span')
        if (span) {
          span.classList.remove('text-blue-900', 'font-semibold')
          span.classList.add('text-gray-900')
        }
      }
    })

    const dropdownButton = this.element.querySelector('[data-dropdown-target="button"]')
    if (dropdownButton) {
      const labelSpan = dropdownButton.querySelector('span')
      if (labelSpan) {
        const selectedItem = Array.from(leftPanelItems).find(item => {
          const itemLoomFile = item.dataset.loomFile || item.getAttribute('data-loom-file')
          return itemLoomFile === selectedLoomFile
        })
        if (selectedItem) {
          const itemLabel = selectedItem.querySelector('strong')?.textContent || selectedLoomFile
          labelSpan.textContent = itemLabel
        }
      }
    }
  }
}
