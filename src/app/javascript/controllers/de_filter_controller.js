import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fdrCutoff", "fcCutoff", "filterBtn", "resultsContainer"]
  static values = { url: String }

  connect() {
    console.log('[DeFilterController] Connected, url:', this.urlValue)
  }

  filter() {
    const btn = this.filterBtnTarget
    btn.disabled = true
    btn.textContent = 'Filtering...'

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
      btn.disabled = false
      btn.textContent = 'Filter'
    })
    .catch(error => {
      console.error('[DeFilterController] Error:', error)
      container.innerHTML = '<div class="text-red-600">Error filtering DE results.</div>'
      btn.disabled = false
      btn.textContent = 'Filter'
    })
  }

  filterOnEnter(event) {
    if (event.keyCode === 13) this.filter()
  }
}
