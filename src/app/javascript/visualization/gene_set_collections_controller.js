export class GeneSetCollectionsController {
  constructor(controller) {
    this.controller = controller
    this.projectIdentifier = this.resolveProjectIdentifier()
    this.selectedCollectionId = null
    this.detailFilterTimer = null
    this.geneSetGenesCache = new Map()
    this.activeGenesPopover = null
    this.geneDetailsModal = null
    this.activeCollectionDownloadMenu = null
    this.init()
  }

  resolveProjectIdentifier() {
    if (this.controller && typeof this.controller.getProjectIdentifier === 'function') {
      const fromController = this.controller.getProjectIdentifier()
      if (fromController) return fromController
    }
    const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
    return pathMatch ? pathMatch[1] : null
  }

  init() {
    this.filterInput = document.getElementById('gene-set-collections-name-filter-input')
    this.listBody = document.getElementById('gene-set-collections-table-body')
    this.emptyMessage = document.getElementById('gene-set-collections-empty-message')
    this.listView = document.getElementById('gene-set-collections-list-view')
    this.detailView = document.getElementById('gene-set-collection-detail-view')
    this.detailTitle = document.getElementById('gene-set-collection-detail-title')
    this.detailBackBtn = document.getElementById('gene-set-collection-back-btn')
    this.itemsFilterInput = document.getElementById('gene-set-items-name-filter-input')
    this.itemsCountLabel = document.getElementById('gene-set-items-count-label')
    this.itemsList = document.getElementById('gene-set-items-list')
    this.itemsEmptyMessage = document.getElementById('gene-set-items-empty-message')

    if (!this.listBody || !this.emptyMessage) return

    this.bindListFilter()
    this.bindCollectionRowClicks()
    this.bindBackButton()
    this.bindDetailFilter()
    this.bindDeleteButtons()
    this.bindDownloadButtons()
    this.applyListFilter()
  }

  escapeHtml(value) {
    return String(value || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;')
  }

  confirmDestructiveAction(message) {
    return new Promise((resolve) => {
      const overlay = document.createElement('div')
      overlay.style.position = 'fixed'
      overlay.style.inset = '0'
      overlay.style.background = 'rgba(17, 24, 39, 0.35)'
      overlay.style.zIndex = '7000'
      overlay.style.display = 'flex'
      overlay.style.alignItems = 'center'
      overlay.style.justifyContent = 'center'
      overlay.style.padding = '16px'

      const dialog = document.createElement('div')
      dialog.setAttribute('role', 'dialog')
      dialog.setAttribute('aria-modal', 'true')
      dialog.style.width = '100%'
      dialog.style.maxWidth = '420px'
      dialog.style.background = '#ffffff'
      dialog.style.border = '1px solid #e5e7eb'
      dialog.style.borderRadius = '8px'
      dialog.style.boxShadow = '0 18px 38px rgba(15, 23, 42, 0.2)'
      dialog.style.padding = '14px'

      const body = document.createElement('div')
      body.style.fontSize = '14px'
      body.style.color = '#111827'
      body.style.marginBottom = '12px'
      body.textContent = String(message || 'Are you sure?')

      const actions = document.createElement('div')
      actions.style.display = 'flex'
      actions.style.justifyContent = 'flex-end'
      actions.style.gap = '8px'

      const cancelButton = document.createElement('button')
      cancelButton.type = 'button'
      cancelButton.textContent = 'Cancel'
      cancelButton.style.padding = '6px 10px'
      cancelButton.style.fontSize = '12px'
      cancelButton.style.border = '1px solid #d1d5db'
      cancelButton.style.borderRadius = '6px'
      cancelButton.style.background = '#ffffff'
      cancelButton.style.color = '#374151'
      cancelButton.style.cursor = 'pointer'

      const confirmButton = document.createElement('button')
      confirmButton.type = 'button'
      confirmButton.textContent = 'Delete'
      confirmButton.style.padding = '6px 10px'
      confirmButton.style.fontSize = '12px'
      confirmButton.style.border = '1px solid #dc2626'
      confirmButton.style.borderRadius = '6px'
      confirmButton.style.background = '#dc2626'
      confirmButton.style.color = '#ffffff'
      confirmButton.style.cursor = 'pointer'

      let closed = false
      const close = (result) => {
        if (closed) return
        closed = true
        document.removeEventListener('keydown', onKeyDown)
        overlay.remove()
        resolve(result)
      }
      const onKeyDown = (event) => {
        if (event.key === 'Escape') {
          event.preventDefault()
          close(false)
        }
      }

      cancelButton.addEventListener('click', () => close(false))
      confirmButton.addEventListener('click', () => close(true))
      overlay.addEventListener('click', (event) => {
        if (event.target === overlay) close(false)
      })

      actions.appendChild(cancelButton)
      actions.appendChild(confirmButton)
      dialog.appendChild(body)
      dialog.appendChild(actions)
      overlay.appendChild(dialog)
      document.body.appendChild(overlay)
      document.addEventListener('keydown', onKeyDown)
      confirmButton.focus()
    })
  }

  applyListFilter() {
    const query = (this.filterInput?.value || '').trim().toLowerCase()
    const rows = Array.from(this.listBody.querySelectorAll('[data-gene-set-collection-row="true"]'))
    let visibleCount = 0

    rows.forEach((row) => {
      const name = (row.dataset.collectionName || '').toLowerCase()
      const isVisible = query === '' || name.includes(query)
      row.style.display = isVisible ? 'flex' : 'none'
      if (isVisible) visibleCount += 1
    })

    this.emptyMessage.style.display = visibleCount === 0 ? 'block' : 'none'
  }

  bindListFilter() {
    if (!this.filterInput || this.filterInput.dataset.bound === 'true') return
    this.filterInput.dataset.bound = 'true'
    this.filterInput.addEventListener('input', () => this.applyListFilter())
  }

  renderCollectionItems(items) {
    if (!this.itemsList || !this.itemsEmptyMessage) return

    if (!Array.isArray(items) || items.length === 0) {
      this.closeGeneSetGenesPopover()
      this.itemsList.innerHTML = ''
      this.itemsEmptyMessage.style.display = 'block'
      return
    }

    this.itemsEmptyMessage.style.display = 'none'
    this.itemsList.innerHTML = items.map((item) => {
      const rawName = typeof item.name === 'string' ? item.name.trim() : ''
      const titleHtml = rawName
        ? this.escapeHtml(rawName)
        : '<span style="font-style:italic;">Unnamed Gene Set</span>'
      const totalGenes = Number(item.gene_count || 0)
      const inDatasetGenes = Number(item.in_dataset_count || 0)
      const geneLabel = totalGenes === 1 ? 'gene' : 'genes'
      const countLabel = `${inDatasetGenes} / ${totalGenes} ${geneLabel} in dataset`
      const itemId = String(item.id || '').trim()
      const canColor = item.supports_module_score !== false
      const canDelete = item.deletable === true
      let createdAtLabel = ''
      if (item.created_at) {
        const parsedDate = new Date(item.created_at)
        if (!Number.isNaN(parsedDate.getTime())) {
          createdAtLabel = parsedDate.toLocaleString()
        }
      }
      const identifierLabel = this.escapeHtml(item.identifier || '-')

      return `
        <div data-gene-set-item-row="true"
             data-gene-set-item-id="${itemId}"
             style="width:100%;display:flex;align-items:center;justify-content:space-between;padding:5px 8px;background-color:white;border-radius:6px;border:1px solid #e5e7eb;cursor:pointer;gap:8px;">
          <div style="flex:1;min-width:0;">
            <div style="font-size:13px;font-weight:600;color:#111827;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.2;">
              ${titleHtml}
            </div>
            <div style="font-size:11px;color:#6b7280;line-height:1.2;margin-top:2px;">
              ${identifierLabel} |
              <button type="button"
                      data-gene-set-genes-preview-btn="true"
                      data-gene-set-item-id="${itemId}"
                      style="border:none;background:none;padding:0;margin:0;color:#6b7280;font-size:11px;line-height:1.2;cursor:pointer;text-decoration:none;transition:color 0.15s;"
                      title="Show genes in dataset"
                      onmouseover="this.style.color='#2563eb'"
                      onmouseout="this.style.color='#6b7280'"
                      onclick="event.stopPropagation()">
                ${countLabel}
              </button>
            </div>
            ${createdAtLabel ? `<div style="font-size:11px;color:#6b7280;line-height:1.2;margin-top:2px;">Created: ${this.escapeHtml(createdAtLabel)}</div>` : ''}
          </div>
          <div style="display:flex;align-items:center;justify-content:flex-end;flex:0 0 auto;">
            ${canColor ? `
            <button class="gene-set-color-btn"
                    data-action="click->visualization#geneSetWaterDropClicked"
                    data-gene-set-item-id="${itemId}"
                    data-gene-set-name="${this.escapeHtml(rawName || 'Unnamed Gene Set')}"
                    data-active="false"
                    style="padding:4px;color:#9ca3af;background:none;border:none;border-radius:4px;cursor:pointer;transition:all 0.2s;"
                    onmouseover="if(this.dataset.active !== 'true') { this.style.color='#6b7280'; this.style.backgroundColor='#f3f4f6'; }"
                    onmouseout="if(this.dataset.active !== 'true') { this.style.color='#9ca3af'; this.style.backgroundColor=''; }"
                    title="Color by gene set expression"
                    onclick="event.stopPropagation()">
              <i class="fas fa-palette" style="font-size:16px;"></i>
            </button>
            ` : ''}
            ${canDelete ? `
            <button type="button"
                    data-manual-gene-set-delete-btn="true"
                    data-gene-set-item-id="${itemId}"
                    style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;color:#dc2626;background:none;border:none;cursor:pointer;padding:0;margin-left:4px;"
                    title="Delete manual gene set"
                    onclick="event.stopPropagation()">
              <i class="fas fa-trash" style="font-size:12px;"></i>
            </button>
            ` : ''}
          </div>
        </div>
      `
    }).join('')

    this.bindGeneSetItemClicks()
    this.bindGeneSetCountPreviewButtons()
    this.bindManualGeneSetDeleteButtons()
  }

  async loadGeneSetItemIntoGenePanel(itemId) {
    const payload = await this.fetchGeneSetItemGenes(itemId)
    const geneManager = this.controller?.geneManager
    if (!geneManager || typeof geneManager.replaceGenesFromGeneSet !== 'function') {
      throw new Error('Gene panel is not available')
    }
    await geneManager.replaceGenesFromGeneSet(payload.genes || [])
  }

  async fetchGeneSetItemGenes(itemId) {
    if (!this.projectIdentifier || !itemId) return { genes: [] }
    const currentLoomFile = this.controller?.getCurrentLoomFileForRequest?.() || this.controller?.currentLoomFile || ''
    const params = new URLSearchParams({
      item_id: String(itemId),
      loom_file: String(currentLoomFile || '')
    })
    const response = await fetch(`/projects/${encodeURIComponent(this.projectIdentifier)}/gene_set_item_genes?${params.toString()}`, {
      method: 'GET',
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json' }
    })

    const payload = await response.json()
    if (!response.ok || payload.status !== 'ok') {
      throw new Error(payload.message || 'Failed to load genes from gene set')
    }
    return payload
  }

  bindGeneSetItemClicks() {
    if (!this.itemsList) return
    const rows = this.itemsList.querySelectorAll('[data-gene-set-item-row="true"]')
    rows.forEach((row) => {
      if (row.dataset.bound === 'true') return
      row.dataset.bound = 'true'
      row.addEventListener('click', async (event) => {
        if (event.target.closest('.gene-set-color-btn')) return
        if (event.target.closest('[data-gene-set-genes-preview-btn="true"]')) return
        const itemId = String(row.dataset.geneSetItemId || '').trim()
        if (!itemId) return
        try {
          await this.loadGeneSetItemIntoGenePanel(itemId)
        } catch (error) {
          alert(error.message || 'Failed to load genes from gene set')
        }
      })
    })
  }

  bindGeneSetCountPreviewButtons() {
    if (!this.itemsList) return
    const buttons = this.itemsList.querySelectorAll('[data-gene-set-genes-preview-btn="true"]')
    buttons.forEach((button) => {
      if (button.dataset.bound === 'true') return
      button.dataset.bound = 'true'
      button.addEventListener('click', async (event) => {
        event.preventDefault()
        event.stopPropagation()
        const itemId = String(button.dataset.geneSetItemId || '').trim()
        if (!itemId) return
        try {
          await this.toggleGeneSetGenesPopover(button, itemId)
        } catch (error) {
          alert(error.message || 'Failed to load genes from gene set')
        }
      })
    })
  }

  bindManualGeneSetDeleteButtons() {
    if (!this.itemsList) return
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
    const buttons = this.itemsList.querySelectorAll('[data-manual-gene-set-delete-btn="true"]')
    buttons.forEach((button) => {
      if (button.dataset.bound === 'true') return
      button.dataset.bound = 'true'
      button.addEventListener('click', async (event) => {
        event.preventDefault()
        event.stopPropagation()
        const itemId = String(button.dataset.geneSetItemId || '').trim()
        if (!itemId || !this.projectIdentifier) return

        const shouldDelete = await this.confirmDestructiveAction('Delete this manual gene set?')
        if (!shouldDelete) return

        button.disabled = true
        const originalHtml = button.innerHTML
        button.innerHTML = '<i class="fas fa-spinner fa-spin" style="font-size:12px;"></i>'
        try {
          const headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          }
          if (csrfToken) headers['X-CSRF-Token'] = csrfToken
          const response = await fetch(`/projects/${encodeURIComponent(this.projectIdentifier)}/delete_manual_gene_set`, {
            method: 'POST',
            credentials: 'same-origin',
            headers,
            body: JSON.stringify({ item_id: itemId })
          })
          const payload = await response.json()
          if (!response.ok || payload.status !== 'ok') {
            throw new Error(payload.message || 'Failed to delete manual gene set')
          }

          if (this.selectedCollectionId) {
            await this.fetchCollectionItems(this.selectedCollectionId, this.itemsFilterInput?.value || '')
          }
          if (payload.collection) {
            this.upsertCollectionFromPayload(payload.collection)
          }
        } catch (error) {
          alert(error.message || 'Failed to delete manual gene set')
          button.disabled = false
          button.innerHTML = originalHtml
        }
      })
    })
  }

  async getGeneSetGenesForPreview(itemId) {
    const cacheKey = String(itemId)
    if (this.geneSetGenesCache.has(cacheKey)) {
      return this.geneSetGenesCache.get(cacheKey)
    }
    const payload = await this.fetchGeneSetItemGenes(itemId)
    const foundGenes = Array.isArray(payload.genes) ? payload.genes : []
    const missingGenes = Array.isArray(payload.missing_genes) ? payload.missing_genes : []
    const data = { foundGenes, missingGenes }
    this.geneSetGenesCache.set(cacheKey, data)
    return data
  }

  async toggleGeneSetGenesPopover(anchorEl, itemId) {
    const normalizedId = String(itemId)
    if (
      this.activeGenesPopover &&
      this.activeGenesPopover.itemId === normalizedId &&
      this.activeGenesPopover.element
    ) {
      this.closeGeneSetGenesPopover()
      return
    }

    this.closeGeneSetGenesPopover()
    const previewData = await this.getGeneSetGenesForPreview(itemId)
    this.openGeneSetGenesPopover(anchorEl, normalizedId, previewData)
  }

  openGeneSetGenesPopover(anchorEl, itemId, previewData) {
    if (!anchorEl) return
    const foundGenes = Array.isArray(previewData?.foundGenes) ? previewData.foundGenes : []
    const missingGenes = Array.isArray(previewData?.missingGenes) ? previewData.missingGenes : []
    const allGenes = foundGenes.concat(missingGenes)

    const popover = document.createElement('div')
    popover.setAttribute('data-gene-set-genes-popover', 'true')
    popover.style.position = 'fixed'
    popover.style.zIndex = '6000'
    popover.style.minWidth = '320px'
    popover.style.maxWidth = '520px'
    popover.style.maxHeight = '300px'
    popover.style.overflow = 'hidden'
    popover.style.background = '#ffffff'
    popover.style.border = '1px solid #dbe3ef'
    popover.style.borderRadius = '10px'
    popover.style.boxShadow = '0 14px 32px rgba(15, 23, 42, 0.16)'
    popover.style.padding = '10px'

    const header = document.createElement('div')
    header.style.display = 'flex'
    header.style.alignItems = 'center'
    header.style.justifyContent = 'space-between'
    header.style.gap = '8px'
    header.style.marginBottom = '8px'

    const title = document.createElement('div')
    title.style.fontSize = '12px'
    title.style.fontWeight = '600'
    title.style.color = '#111827'
    title.textContent = `${foundGenes.length} found, ${missingGenes.length} not found`
    header.appendChild(title)

    const closeBtn = document.createElement('button')
    closeBtn.type = 'button'
    closeBtn.style.border = 'none'
    closeBtn.style.background = 'none'
    closeBtn.style.color = '#6b7280'
    closeBtn.style.cursor = 'pointer'
    closeBtn.style.padding = '2px 4px'
    closeBtn.style.borderRadius = '4px'
    closeBtn.title = 'Close'
    closeBtn.innerHTML = '<i class="fas fa-times" style="font-size:12px;"></i>'
    closeBtn.addEventListener('click', (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.closeGeneSetGenesPopover()
    })
    header.appendChild(closeBtn)
    popover.appendChild(header)

    const controls = document.createElement('div')
    controls.style.display = 'flex'
    controls.style.gap = '6px'
    controls.style.flexWrap = 'wrap'
    controls.style.marginBottom = '8px'

    const makeCopyButton = (label, extractor) => {
      const btn = document.createElement('button')
      btn.type = 'button'
      btn.style.display = 'inline-flex'
      btn.style.alignItems = 'center'
      btn.style.gap = '6px'
      btn.style.padding = '5px 8px'
      btn.style.fontSize = '11px'
      btn.style.fontWeight = '600'
      btn.style.color = '#1f2937'
      btn.style.background = '#f3f4f6'
      btn.style.border = '1px solid #d1d5db'
      btn.style.borderRadius = '6px'
      btn.style.cursor = 'pointer'
      btn.innerHTML = `<i class="fas fa-copy" style="font-size:11px;"></i><span>${label}</span>`
      btn.addEventListener('click', async (event) => {
        event.preventDefault()
        event.stopPropagation()
        const text = allGenes
          .map((gene) => extractor(gene))
          .map((v) => String(v || '').trim())
          .filter((v) => v.length > 0)
          .join(' ')
        await navigator.clipboard.writeText(text)
        btn.style.background = '#dbeafe'
        window.setTimeout(() => {
          btn.style.background = '#f3f4f6'
        }, 500)
      })
      return btn
    }

    controls.appendChild(makeCopyButton('Ensembl IDs', (gene) => gene?.ensembl_id || gene?.ensemblId))
    controls.appendChild(makeCopyButton('Gene symbols', (gene) => gene?.symbol))
    popover.appendChild(controls)

    const sectionsWrap = document.createElement('div')
    sectionsWrap.style.display = 'flex'
    sectionsWrap.style.flexDirection = 'column'
    sectionsWrap.style.gap = '10px'
    sectionsWrap.style.maxHeight = '208px'
    sectionsWrap.style.overflowY = 'auto'
    sectionsWrap.style.paddingRight = '2px'

    const buildGeneSection = (sectionTitle, genes, palette = 'blue') => {
      const section = document.createElement('div')
      const titleEl = document.createElement('div')
      titleEl.style.fontSize = '11px'
      titleEl.style.fontWeight = '700'
      titleEl.style.marginBottom = '6px'
      titleEl.style.color = palette === 'red' ? '#b91c1c' : '#1e40af'
      titleEl.textContent = `${sectionTitle} (${genes.length})`
      section.appendChild(titleEl)

      const badgeWrap = document.createElement('div')
      badgeWrap.style.display = 'flex'
      badgeWrap.style.flexWrap = 'wrap'
      badgeWrap.style.gap = '6px'

      if (!genes.length) {
        const empty = document.createElement('div')
        empty.style.fontSize = '12px'
        empty.style.color = '#6b7280'
        empty.style.fontStyle = 'italic'
        empty.textContent = 'None'
        badgeWrap.appendChild(empty)
      } else {
        genes.forEach((gene) => {
          const label = String(gene?.symbol || gene?.ensembl_id || gene?.ensemblId || gene?.stable_id || '').trim()
          if (!label) return
          const badge = document.createElement('button')
          badge.type = 'button'
          badge.className = 'gene-badge cursor-pointer inline-flex items-center px-2 py-0.5 rounded text-xs font-medium'
          if (palette === 'red') {
            badge.className += ' bg-gray-100 text-gray-500 hover:bg-gray-200'
          } else {
            badge.className += ' bg-blue-100 text-blue-800 hover:bg-blue-200'
          }
          badge.textContent = label
          badge.title = String(gene?.ensembl_id || gene?.ensemblId || label)
          badge.addEventListener('click', async (event) => {
            event.preventDefault()
            event.stopPropagation()
            try {
              await this.openGeneDetailsModal(gene)
            } catch (error) {
              alert(error.message || 'Failed to load gene details')
            }
          })
          badgeWrap.appendChild(badge)
        })
      }

      section.appendChild(badgeWrap)
      return section
    }

    sectionsWrap.appendChild(buildGeneSection('Found in dataset', foundGenes, 'blue'))
    sectionsWrap.appendChild(buildGeneSection('Not found in dataset', missingGenes, 'red'))
    popover.appendChild(sectionsWrap)
    document.body.appendChild(popover)
    this.positionGeneSetGenesPopover(anchorEl, popover)

    const onDocumentPointerDown = (event) => {
      if (this.geneDetailsModal?.overlay && this.geneDetailsModal.overlay.contains(event.target)) {
        return
      }
      if (!popover.contains(event.target) && !anchorEl.contains(event.target)) {
        this.closeGeneSetGenesPopover()
      }
    }
    const onWindowResize = () => {
      if (!this.activeGenesPopover?.element) return
      this.positionGeneSetGenesPopover(anchorEl, popover)
    }

    document.addEventListener('mousedown', onDocumentPointerDown)
    window.addEventListener('resize', onWindowResize)

    this.activeGenesPopover = {
      itemId,
      element: popover,
      onDocumentPointerDown,
      onWindowResize
    }
  }

  positionGeneSetGenesPopover(anchorEl, popover) {
    if (!anchorEl || !popover) return
    const anchorRect = anchorEl.getBoundingClientRect()
    const maxWidth = 520
    const margin = 10
    let left = anchorRect.right - maxWidth
    if (left < margin) left = margin
    let top = anchorRect.bottom + 8
    const viewportBottom = window.innerHeight - margin
    const expectedHeight = 300
    if (top + expectedHeight > viewportBottom) {
      top = Math.max(margin, anchorRect.top - expectedHeight - 8)
    }
    popover.style.left = `${left}px`
    popover.style.top = `${top}px`
  }

  closeGeneSetGenesPopover() {
    if (!this.activeGenesPopover) return
    const { element, onDocumentPointerDown, onWindowResize } = this.activeGenesPopover
    if (element?.parentNode) {
      element.parentNode.removeChild(element)
    }
    if (onDocumentPointerDown) {
      document.removeEventListener('mousedown', onDocumentPointerDown)
    }
    if (onWindowResize) {
      window.removeEventListener('resize', onWindowResize)
    }
    this.activeGenesPopover = null
  }

  ensureGeneDetailsModal() {
    if (this.geneDetailsModal && this.geneDetailsModal.overlay && document.body.contains(this.geneDetailsModal.overlay)) {
      return this.geneDetailsModal
    }

    const overlay = document.createElement('div')
    overlay.style.display = 'none'
    overlay.style.position = 'fixed'
    overlay.style.top = '0'
    overlay.style.left = '0'
    overlay.style.right = '0'
    overlay.style.bottom = '0'
    overlay.style.zIndex = '7000'
    overlay.style.backgroundColor = 'rgba(0, 0, 0, 0.5)'
    overlay.style.alignItems = 'center'
    overlay.style.justifyContent = 'center'

    const modal = document.createElement('div')
    modal.style.background = '#ffffff'
    modal.style.borderRadius = '10px'
    modal.style.boxShadow = '0 18px 35px rgba(15, 23, 42, 0.3)'
    modal.style.width = 'min(680px, calc(100vw - 32px))'
    modal.style.maxHeight = '80vh'
    modal.style.display = 'flex'
    modal.style.flexDirection = 'column'
    modal.style.overflow = 'hidden'

    const header = document.createElement('div')
    header.style.display = 'flex'
    header.style.alignItems = 'center'
    header.style.justifyContent = 'space-between'
    header.style.padding = '12px 16px'
    header.style.borderBottom = '1px solid #e5e7eb'
    header.style.background = 'linear-gradient(to right, #eff6ff, #eef2ff)'

    const title = document.createElement('h3')
    title.style.margin = '0'
    title.style.fontSize = '16px'
    title.style.fontWeight = '600'
    title.style.color = '#111827'
    title.textContent = 'Gene details'

    const closeBtn = document.createElement('button')
    closeBtn.type = 'button'
    closeBtn.style.border = 'none'
    closeBtn.style.background = 'none'
    closeBtn.style.color = '#6b7280'
    closeBtn.style.cursor = 'pointer'
    closeBtn.style.width = '28px'
    closeBtn.style.height = '28px'
    closeBtn.style.borderRadius = '6px'
    closeBtn.style.display = 'inline-flex'
    closeBtn.style.alignItems = 'center'
    closeBtn.style.justifyContent = 'center'
    closeBtn.title = 'Close'
    closeBtn.innerHTML = '<i class="fas fa-times" style="font-size:13px;"></i>'

    const body = document.createElement('div')
    body.style.padding = '16px'
    body.style.overflowY = 'auto'
    body.style.fontSize = '13px'
    body.style.color = '#374151'
    body.innerHTML = '<div style="color:#6b7280;">Loading...</div>'

    header.appendChild(title)
    header.appendChild(closeBtn)
    modal.appendChild(header)
    modal.appendChild(body)
    overlay.appendChild(modal)
    document.body.appendChild(overlay)

    const close = () => {
      overlay.style.display = 'none'
    }
    closeBtn.addEventListener('click', (event) => {
      event.preventDefault()
      event.stopPropagation()
      close()
    })
    overlay.addEventListener('click', (event) => {
      if (event.target === overlay) close()
    })

    this.geneDetailsModal = { overlay, title, body }
    return this.geneDetailsModal
  }

  async openGeneDetailsModal(gene) {
    const modal = this.ensureGeneDetailsModal()
    if (!modal) return

    const ensemblId = String(gene?.ensembl_id || gene?.ensemblId || '').trim()
    const geneLabel = String(gene?.symbol || ensemblId || 'Gene').trim()

    modal.overlay.style.display = 'flex'
    modal.title.textContent = geneLabel
    modal.body.innerHTML = '<div style="color:#6b7280;">Loading...</div>'

    if (!ensemblId) {
      modal.body.innerHTML = '<div style="color:#b91c1c;">Gene details are unavailable for this entry.</div>'
      return
    }

    const response = await fetch(`/projects/${encodeURIComponent(this.projectIdentifier)}/search_gene?ensembl_id=${encodeURIComponent(ensemblId)}`, {
      method: 'GET',
      credentials: 'same-origin',
      headers: { 'Accept': 'text/html' }
    })

    const html = await response.text()
    if (!response.ok) {
      throw new Error('Failed to load gene details')
    }
    modal.body.innerHTML = html
  }

  async fetchCollectionItems(collectionId, queryText = '') {
    if (!this.projectIdentifier || !collectionId) return

    const currentLoomFile = this.controller?.getCurrentLoomFileForRequest?.() || this.controller?.currentLoomFile || ''
    const params = new URLSearchParams({
      collection_id: String(collectionId),
      query: String(queryText || ''),
      loom_file: String(currentLoomFile || '')
    })
    const response = await fetch(`/projects/${encodeURIComponent(this.projectIdentifier)}/gene_set_collection_items?${params.toString()}`, {
      method: 'GET',
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json' }
    })

    const payload = await response.json()
    if (!response.ok || payload.status !== 'ok') {
      throw new Error(payload.message || 'Failed to load gene sets')
    }

    if (this.detailTitle) {
      this.detailTitle.textContent = payload.collection?.label || ''
    }

    const totalCount = Number(payload.total_count || 0)
    const displayedCount = Array.isArray(payload.items) ? payload.items.length : 0
    const limit = Number(payload.limit || 100)

    if (this.itemsCountLabel) {
      if (totalCount > limit) {
        this.itemsCountLabel.style.display = 'inline'
        this.itemsCountLabel.textContent = `${displayedCount} out of ${totalCount}`
      } else {
        this.itemsCountLabel.style.display = 'none'
        this.itemsCountLabel.textContent = ''
      }
    }

    this.closeGeneSetGenesPopover()
    this.renderCollectionItems(payload.items || [])
  }

  async openCollectionDetail(collectionId, collectionLabel) {
    this.selectedCollectionId = collectionId
    if (this.itemsFilterInput) this.itemsFilterInput.value = ''
    if (this.detailTitle) this.detailTitle.textContent = collectionLabel || ''

    if (this.listView) this.listView.style.display = 'none'
    if (this.detailView) this.detailView.style.display = 'flex'

    await this.fetchCollectionItems(collectionId, '')
  }

  closeCollectionDetail() {
    this.closeGeneSetGenesPopover()
    this.selectedCollectionId = null
    if (this.itemsFilterInput) this.itemsFilterInput.value = ''
    if (this.itemsCountLabel) {
      this.itemsCountLabel.style.display = 'none'
      this.itemsCountLabel.textContent = ''
    }
    if (this.itemsList) this.itemsList.innerHTML = ''
    if (this.itemsEmptyMessage) this.itemsEmptyMessage.style.display = 'none'
    if (this.detailView) this.detailView.style.display = 'none'
    if (this.listView) this.listView.style.display = 'flex'
  }

  upsertCollectionFromPayload(collection) {
    if (!this.listBody || !collection || typeof collection !== 'object') return
    const collectionId = String(collection.id || '').trim()
    if (!collectionId) return

    const label = String(collection.label || '').trim() || 'Manual Gene Sets'
    const itemCount = Number(collection.nb_items || collection.item_count || 0)
    const itemLabel = itemCount === 1 ? 'gene set' : 'gene sets'
    const isCustom = collection.custom === true
    const isImportPending = collection.import_pending === true
    const row = this.listBody.querySelector(`[data-gene-set-collection-row="true"][data-collection-id="${collectionId}"]`)
    if (row) {
      row.style.cssText = 'width:100%;display:flex;align-items:center;justify-content:space-between;padding:5px 8px;background-color:white;border-radius:6px;border:1px solid #e5e7eb;cursor:pointer;gap:8px;'
      row.dataset.collectionLabel = label
      row.dataset.collectionName = label.toLowerCase()
      const titleEl = row.querySelector('[data-role="collection-label"]') || row.querySelector('div > div')
      const countEl = row.querySelector('[data-role="collection-count"]') || row.querySelector('div > div:nth-child(2)')
      const actionsEl = row.querySelector('[data-role="collection-actions"]') || row.lastElementChild
      if (titleEl) titleEl.textContent = label
      if (countEl) countEl.textContent = `${itemCount} ${itemLabel}`
      if (actionsEl) {
        actionsEl.style.display = 'flex'
        actionsEl.style.alignItems = 'center'
        actionsEl.style.justifyContent = 'flex-end'
        actionsEl.style.flex = '0 0 auto'
        actionsEl.innerHTML = isImportPending ? `
          <span style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;color:#6b7280;" title="Import in progress">
            <i class="fas fa-spinner fa-spin" style="font-size:12px;"></i>
          </span>
        ` : `
          ${isCustom ? `
          <button type="button"
                  data-gene-set-delete-btn="true"
                  data-collection-id="${collectionId}"
                  style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;color:#dc2626;background:none;border:none;cursor:pointer;padding:0;"
                  title="Delete custom gene set collection"
                  aria-label="Delete custom gene set collection">
            <i class="fas fa-trash" style="font-size:12px;"></i>
          </button>
          ` : ''}
          <button type="button"
                  data-gene-set-download-btn="true"
                  data-collection-id="${collectionId}"
                  data-collection-label="${this.escapeHtml(label)}"
                  style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;padding:0;color:#374151;background:none;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;line-height:1;margin-left:4px;"
                  title="Download gene set collection"
                  aria-label="Download gene set collection">
            <i class="fas fa-download" style="font-size:11px;"></i>
          </button>
        `
      }
    } else {
      const newRow = document.createElement('div')
      newRow.setAttribute('data-gene-set-collection-row', 'true')
      newRow.setAttribute('data-collection-id', collectionId)
      newRow.setAttribute('data-collection-label', label)
      newRow.setAttribute('data-collection-name', label.toLowerCase())
      newRow.style.cssText = 'width:100%;display:flex;align-items:center;justify-content:space-between;padding:5px 8px;background-color:white;border-radius:6px;border:1px solid #e5e7eb;cursor:pointer;gap:8px;'
      newRow.innerHTML = `
        <div style="flex:1;min-width:0;">
          <div data-role="collection-label" style="font-size:13px;font-weight:600;color:#111827;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;line-height:1.2;">${this.escapeHtml(label)}</div>
          <div data-role="collection-count" style="font-size:11px;color:#6b7280;line-height:1.2;margin-top:2px;">${itemCount} ${itemLabel}</div>
        </div>
        <div data-role="collection-actions" style="display:flex;align-items:center;justify-content:flex-end;flex:0 0 auto;">
          ${isImportPending ? `
            <span style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;color:#6b7280;" title="Import in progress">
              <i class="fas fa-spinner fa-spin" style="font-size:12px;"></i>
            </span>
          ` : `
            ${isCustom ? `
            <button type="button"
                    data-gene-set-delete-btn="true"
                    data-collection-id="${collectionId}"
                    style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;color:#dc2626;background:none;border:none;cursor:pointer;padding:0;"
                    title="Delete custom gene set collection"
                    aria-label="Delete custom gene set collection">
              <i class="fas fa-trash" style="font-size:12px;"></i>
            </button>
            ` : ''}
            <button type="button"
                    data-gene-set-download-btn="true"
                    data-collection-id="${collectionId}"
                    data-collection-label="${this.escapeHtml(label)}"
                    style="display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;padding:0;color:#374151;background:none;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;line-height:1;margin-left:4px;"
                    title="Download gene set collection"
                    aria-label="Download gene set collection">
              <i class="fas fa-download" style="font-size:11px;"></i>
            </button>
          `}
        </div>
      `
      this.listBody.prepend(newRow)
    }

    this.bindCollectionRowClicks()
    this.bindDeleteButtons()
    this.bindDownloadButtons()
    this.applyListFilter()
  }

  bindCollectionRowClicks() {
    const rows = this.listBody.querySelectorAll('[data-gene-set-collection-row="true"]')
    rows.forEach((row) => {
      if (row.dataset.openBound === 'true') return
      row.dataset.openBound = 'true'
      row.addEventListener('click', async (event) => {
        if (event.target.closest('[data-gene-set-delete-btn="true"]')) return
        const collectionId = row.dataset.collectionId
        const collectionLabel = row.dataset.collectionLabel || ''
        if (!collectionId) return
        try {
          await this.openCollectionDetail(collectionId, collectionLabel)
        } catch (error) {
          alert(error.message || 'Failed to load gene sets')
        }
      })
    })
  }

  bindBackButton() {
    if (!this.detailBackBtn || this.detailBackBtn.dataset.bound === 'true') return
    this.detailBackBtn.dataset.bound = 'true'
    this.detailBackBtn.addEventListener('click', (event) => {
      event.preventDefault()
      event.stopPropagation()
      this.closeCollectionDetail()
    })
  }

  bindDetailFilter() {
    if (!this.itemsFilterInput || this.itemsFilterInput.dataset.bound === 'true') return
    this.itemsFilterInput.dataset.bound = 'true'
    this.itemsFilterInput.addEventListener('input', () => {
      if (!this.selectedCollectionId) return
      if (this.detailFilterTimer) clearTimeout(this.detailFilterTimer)
      this.detailFilterTimer = setTimeout(async () => {
        try {
          await this.fetchCollectionItems(this.selectedCollectionId, this.itemsFilterInput.value || '')
        } catch (error) {
          alert(error.message || 'Failed to load gene sets')
        }
      }, 250)
    })
  }

  bindDeleteButtons() {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
    const deleteButtons = this.listBody.querySelectorAll('[data-gene-set-delete-btn="true"]')

    deleteButtons.forEach((button) => {
      if (button.dataset.bound === 'true') return
      button.dataset.bound = 'true'

      button.addEventListener('click', async (event) => {
        event.preventDefault()
        event.stopPropagation()

        const collectionId = button.dataset.collectionId
        if (!collectionId || !this.projectIdentifier) return

        const shouldDelete = await this.confirmDestructiveAction('Delete this custom gene set collection?')
        if (!shouldDelete) return

        button.disabled = true
        const originalLabel = button.textContent
        button.textContent = 'Deleting...'

        try {
          const headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          }
          if (csrfToken) headers['X-CSRF-Token'] = csrfToken

          const response = await fetch(`/projects/${encodeURIComponent(this.projectIdentifier)}/delete_gene_set_collection`, {
            method: 'POST',
            headers,
            credentials: 'same-origin',
            body: JSON.stringify({ collection_id: collectionId })
          })

          const payload = await response.json()
          if (!response.ok || payload.status !== 'ok') {
            throw new Error(payload.message || 'Failed to delete gene set collection')
          }

          const row = button.closest('[data-gene-set-collection-row="true"]')
          if (row) row.remove()
          this.applyListFilter()

          if (this.selectedCollectionId && String(this.selectedCollectionId) === String(collectionId)) {
            this.closeCollectionDetail()
          }
        } catch (error) {
          alert(error.message || 'Failed to delete gene set collection')
          button.disabled = false
          button.textContent = originalLabel
        }
      })
    })
  }

  bindDownloadButtons() {
    const buttons = this.listBody.querySelectorAll('[data-gene-set-download-btn="true"]')
    buttons.forEach((button) => {
      if (button.dataset.boundDownload === 'true') return
      button.dataset.boundDownload = 'true'
      button.addEventListener('click', (event) => {
        event.preventDefault()
        event.stopPropagation()
        const collectionId = String(button.dataset.collectionId || '').trim()
        const collectionLabel = String(button.dataset.collectionLabel || '').trim()
        if (!collectionId || !this.projectIdentifier) return
        this.toggleCollectionDownloadMenu(button, collectionId, collectionLabel)
      })
    })
  }

  toggleCollectionDownloadMenu(anchorEl, collectionId, collectionLabel) {
    if (
      this.activeCollectionDownloadMenu &&
      this.activeCollectionDownloadMenu.collectionId === String(collectionId) &&
      this.activeCollectionDownloadMenu.element
    ) {
      this.closeCollectionDownloadMenu()
      return
    }

    this.closeCollectionDownloadMenu()
    this.openCollectionDownloadMenu(anchorEl, collectionId, collectionLabel)
  }

  openCollectionDownloadMenu(anchorEl, collectionId, collectionLabel) {
    if (!anchorEl) return
    const menu = document.createElement('div')
    menu.setAttribute('data-gene-set-download-menu', 'true')
    menu.style.position = 'fixed'
    menu.style.zIndex = '6500'
    menu.style.minWidth = '190px'
    menu.style.background = '#ffffff'
    menu.style.border = '1px solid #d1d5db'
    menu.style.borderRadius = '6px'
    menu.style.boxShadow = '0 10px 24px rgba(15, 23, 42, 0.12)'
    menu.style.padding = '4px'

    const options = [
      { id: 'json', label: 'JSON' },
      { id: 'gmt_ensembl', label: 'GMT ensemblID' },
      { id: 'gmt_symbol', label: 'GMT gene symbols' }
    ]

    options.forEach((option) => {
      const btn = document.createElement('button')
      btn.type = 'button'
      btn.textContent = option.label
      btn.style.display = 'block'
      btn.style.width = '100%'
      btn.style.textAlign = 'left'
      btn.style.border = 'none'
      btn.style.background = 'none'
      btn.style.padding = '6px 8px'
      btn.style.fontSize = '12px'
      btn.style.color = '#111827'
      btn.style.cursor = 'pointer'
      btn.addEventListener('mouseover', () => { btn.style.background = '#f3f4f6' })
      btn.addEventListener('mouseout', () => { btn.style.background = 'none' })
      btn.addEventListener('click', (event) => {
        event.preventDefault()
        event.stopPropagation()
        this.downloadCollectionFile(collectionId, option.id)
        this.closeCollectionDownloadMenu()
      })
      menu.appendChild(btn)
    })

    document.body.appendChild(menu)
    const anchorRect = anchorEl.getBoundingClientRect()
    let left = anchorRect.right - menu.offsetWidth
    let top = anchorRect.bottom + 6
    if (left < 8) left = 8
    if (top + menu.offsetHeight > window.innerHeight - 8) {
      top = Math.max(8, anchorRect.top - menu.offsetHeight - 6)
    }
    menu.style.left = `${left}px`
    menu.style.top = `${top}px`

    const onDocumentPointerDown = (event) => {
      if (!menu.contains(event.target) && !anchorEl.contains(event.target)) {
        this.closeCollectionDownloadMenu()
      }
    }
    const onWindowResize = () => this.closeCollectionDownloadMenu()

    document.addEventListener('mousedown', onDocumentPointerDown)
    window.addEventListener('resize', onWindowResize)

    this.activeCollectionDownloadMenu = {
      collectionId: String(collectionId),
      collectionLabel: String(collectionLabel || ''),
      element: menu,
      onDocumentPointerDown,
      onWindowResize
    }
  }

  closeCollectionDownloadMenu() {
    if (!this.activeCollectionDownloadMenu) return
    const { element, onDocumentPointerDown, onWindowResize } = this.activeCollectionDownloadMenu
    if (element?.parentNode) {
      element.parentNode.removeChild(element)
    }
    if (onDocumentPointerDown) {
      document.removeEventListener('mousedown', onDocumentPointerDown)
    }
    if (onWindowResize) {
      window.removeEventListener('resize', onWindowResize)
    }
    this.activeCollectionDownloadMenu = null
  }

  downloadCollectionFile(collectionId, exportFormat) {
    if (!this.projectIdentifier || !collectionId || !exportFormat) return
    const currentLoomFile = this.controller?.getCurrentLoomFileForRequest?.() || this.controller?.currentLoomFile || ''
    if (!currentLoomFile) {
      alert('Missing loom file context for export')
      return
    }
    const params = new URLSearchParams({
      collection_id: String(collectionId),
      export_format: String(exportFormat),
      loom_file: String(currentLoomFile)
    })
    window.location.assign(`/projects/${encodeURIComponent(this.projectIdentifier)}/download_gene_set_collection?${params.toString()}`)
  }
}
