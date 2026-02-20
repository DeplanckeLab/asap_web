import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fdrCutoff", "fcCutoff", "resultsContainer", "tableRoot",
                     "pageSize", "pageInfo", "pageNumbersContainer", "prevBtn", "nextBtn"]
  static values = { url: String }

  connect() {
    this._sortCol = null
    this._sortAsc = true
    this._currentPage = 1
  }

  resultsContainerTargetConnected() {
    this._initTable()
  }

  tableRootTargetConnected() {
    this._initTable()
  }

  _initTable() {
    if (!this.hasTableRootTarget) return
    const tbody = this.tableRootTarget.querySelector('tbody')
    if (!tbody) return
    this._allRows = Array.from(tbody.querySelectorAll('tr'))
    this._tbody = tbody
    this._sortCol = null
    this._sortAsc = true
    this._currentPage = 1
    this._doSort(0, true)
  }

  filter() {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content')
    const formData = new FormData()
    formData.append('filter[fdr_cutoff]', this.fdrCutoffTarget.value)
    formData.append('filter[fc_cutoff]', this.fcCutoffTarget.value)

    const container = this.resultsContainerTarget
    container.innerHTML = '<div class="flex justify-center py-8"><div class="text-gray-500">Filtering...</div></div>'

    fetch(this.urlValue, {
      method: 'POST',
      headers: { 'X-CSRF-Token': csrfToken, 'Accept': 'text/html' },
      body: formData
    })
    .then(response => response.text())
    .then(html => {
      container.innerHTML = html
    })
    .catch(error => {
      console.error('[DeFilterController] Error:', error)
      container.innerHTML = '<div class="text-red-600">Error filtering DE results.</div>'
    })
  }

  filterOnEnter(event) {
    if (event.keyCode === 13) this.filter()
  }

  sort(event) {
    const th = event.currentTarget
    const colIdx = parseInt(th.dataset.col, 10)
    this._doSort(colIdx)
  }

  _doSort(colIdx, forceAsc) {
    if (!this._allRows || !this._tbody) return
    if (forceAsc) {
      this._sortCol = colIdx
      this._sortAsc = true
    } else if (this._sortCol === colIdx) {
      this._sortAsc = !this._sortAsc
    } else {
      this._sortCol = colIdx
      this._sortAsc = true
    }

    this._updateSortIndicators()

    const headers = this.tableRootTarget.querySelectorAll('th[data-col]')
    let isNumeric = true
    headers.forEach(th => {
      if (parseInt(th.dataset.col, 10) === colIdx) {
        isNumeric = th.dataset.numeric === 'true'
      }
    })

    const asc = this._sortAsc
    this._allRows.sort(function(a, b) {
      const aVal = a.cells[colIdx].getAttribute('data-sort-value') || ''
      const bVal = b.cells[colIdx].getAttribute('data-sort-value') || ''
      let cmp
      if (isNumeric) {
        cmp = (parseFloat(aVal) || 0) - (parseFloat(bVal) || 0)
      } else {
        cmp = aVal.localeCompare(bVal)
      }
      return asc ? cmp : -cmp
    })

    this._allRows.forEach(row => this._tbody.appendChild(row))
    this._currentPage = 1
    this._renderPage()
  }

  _updateSortIndicators() {
    if (!this.hasTableRootTarget) return
    this.tableRootTarget.querySelectorAll('th[data-col]').forEach(th => {
      const indicator = th.querySelector('.sort-indicator')
      if (!indicator) return
      const col = parseInt(th.dataset.col, 10)
      indicator.textContent = col === this._sortCol ? (this._sortAsc ? ' \u25B2' : ' \u25BC') : ''
    })
  }

  changePage() {
    this._currentPage = 1
    this._renderPage()
  }

  prevPage() {
    if (this._currentPage > 1) {
      this._currentPage--
      this._renderPage()
    }
  }

  nextPage() {
    if (this._currentPage < this._totalPages()) {
      this._currentPage++
      this._renderPage()
    }
  }

  _getPageSize() {
    if (!this.hasPageSizeTarget) return this._allRows ? this._allRows.length : 20
    const v = parseInt(this.pageSizeTarget.value, 10)
    return v === 0 ? (this._allRows ? this._allRows.length : 20) : v
  }

  _totalPages() {
    if (!this._allRows) return 1
    return Math.max(1, Math.ceil(this._allRows.length / this._getPageSize()))
  }

  _renderPage() {
    if (!this._allRows) return
    const ps = this._getPageSize()
    const tp = this._totalPages()
    if (this._currentPage > tp) this._currentPage = tp
    const start = (this._currentPage - 1) * ps
    const end = start + ps
    const visible = new Set(this._allRows.slice(start, end))

    this._allRows.forEach(row => {
      row.style.display = visible.has(row) ? '' : 'none'
    })

    if (this.hasPageInfoTarget) {
      this.pageInfoTarget.textContent = this._allRows.length === 0
        ? '0 of 0'
        : (start + 1) + '-' + Math.min(end, this._allRows.length) + ' of ' + this._allRows.length
    }
    if (this.hasPrevBtnTarget) this.prevBtnTarget.disabled = this._currentPage <= 1
    if (this.hasNextBtnTarget) this.nextBtnTarget.disabled = this._currentPage >= tp

    if (this.hasPageNumbersContainerTarget) {
      const container = this.pageNumbersContainerTarget
      container.innerHTML = ''
      const maxVisible = 7
      const pages = []
      if (tp <= maxVisible) {
        for (let i = 1; i <= tp; i++) pages.push(i)
      } else {
        pages.push(1)
        const lo = Math.max(2, this._currentPage - 1)
        const hi = Math.min(tp - 1, this._currentPage + 1)
        if (lo > 2) pages.push('...')
        for (let i = lo; i <= hi; i++) pages.push(i)
        if (hi < tp - 1) pages.push('...')
        pages.push(tp)
      }
      const self = this
      pages.forEach(p => {
        if (p === '...') {
          const s = document.createElement('span')
          s.className = 'px-1 text-gray-400'
          s.textContent = '...'
          container.appendChild(s)
        } else {
          const btn = document.createElement('button')
          btn.textContent = p
          btn.className = 'px-2.5 py-1 rounded text-sm cursor-pointer ' +
            (p === self._currentPage ? 'bg-blue-600 text-white font-semibold' : 'border border-gray-300 bg-white text-gray-700 hover:bg-gray-100')
          btn.addEventListener('click', function() { self._currentPage = p; self._renderPage() })
          container.appendChild(btn)
        }
      })
    }
  }
}
