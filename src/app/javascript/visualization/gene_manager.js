// GeneManager - Handles gene autocomplete and expression visualization
export class GeneManager {
  constructor(controller) {
    this.controller = controller
    this.autocompleteData = null
    this.currentMatches = []
    this.selectedGene = null
    this.projectIdentifier = null
    this.geneTags = [] // Array of {symbol, ensemblId, stableId, query}
    this.notFoundQueries = [] // Queries that didn't match
    this.init()
  }

  init() {
    console.log('GeneManager: Initializing...')
    // Extract project identifier from URL (could be ID, key, or public_id like ASAP49)
    const pathMatch = window.location.pathname.match(/\/projects\/([^\/]+)/)
    if (pathMatch) {
      this.projectIdentifier = pathMatch[1] // Use identifier instead of just ID
      console.log('GeneManager: Project identifier extracted:', this.projectIdentifier)
    } else {
      console.warn('GeneManager: Could not extract project identifier from URL:', window.location.pathname)
    }

    // Setup combined input field with tags
    const input = document.getElementById('gene-autocomplete-input')
    const tagsContainer = document.getElementById('gene-tags-container')
    if (input && tagsContainer) {
      console.log('GeneManager: Combined input field found, setting up listeners')
      let debounceTimer = null
      
      // Render initial tags (input is already in container from HTML)
      this.renderGeneTags()
      
      input.addEventListener('input', (e) => {
        const value = e.target.value
        console.log('GeneManager: Input event triggered, value:', value)
        
        // Check for separators (comma, space, newline) to process completed genes
        const separatorMatch = value.match(/[,,\s\n]+/)
        if (separatorMatch && value.trim().length > 0) {
          // Process everything before the separator
          const parts = value.split(/[,,\s\n]+/)
          const lastPart = parts.pop() // Keep the last part for autocomplete
          
          // Process completed genes
          for (const part of parts) {
            const trimmed = part.trim()
            if (trimmed) {
              this.processGeneInput(trimmed)
            }
          }
          
          // Update input to only show the current typing part
          input.value = lastPart.trim()
        }
        
        // Handle autocomplete for current input
        clearTimeout(debounceTimer)
        debounceTimer = setTimeout(() => {
          this.handleInput(value.trim())
        }, 300) // Debounce for 300ms
      })

      input.addEventListener('keydown', (e) => {
        // Enter key: process current input if not empty
        if (e.key === 'Enter' && input.value.trim()) {
          e.preventDefault()
          this.processGeneInput(input.value.trim())
          input.value = ''
          this.hideDropdown()
        }
        
        // Backspace on empty input: remove last tag
        if (e.key === 'Backspace' && input.value === '' && this.geneTags.length > 0) {
          e.preventDefault()
          this.removeGeneTag(this.geneTags.length - 1)
        }
      })

      input.addEventListener('focus', () => {
        console.log('GeneManager: Input focused, current value:', input.value)
        if (input.value.trim() && this.currentMatches.length > 0) {
          this.showDropdown()
        }
      })
      
      // Handle paste events for bulk input
      input.addEventListener('paste', (e) => {
        setTimeout(() => {
          const pastedText = input.value
          const genes = this.parseBulkGeneInput(pastedText)
          input.value = ''
          
          // Process all pasted genes
          for (const gene of genes) {
            this.processGeneInput(gene)
          }
          
          // Trigger processing of all genes
          this.processAllGenes()
        }, 10)
      })

    } else {
      console.error('GeneManager: Input field or tags container not found!')
    }

    // Close dropdown when clicking outside
    document.addEventListener('click', (e) => {
      const dropdown = document.getElementById('gene-autocomplete-dropdown')
      const input = document.getElementById('gene-autocomplete-input')
      if (dropdown && input && !dropdown.contains(e.target) && !input.contains(e.target)) {
        this.hideDropdown()
      }
    })

    // Load autocomplete data on page load
    if (this.projectIdentifier) {
      console.log('GeneManager: Loading autocomplete data on initialization...')
      this.loadAutocompleteData()
    }

    // Initialize gene tags and results
    this.geneTags = []
    this.notFoundQueries = []
  }

  updateGeneCountBadge(count) {
    const badge = document.getElementById('gene-count-badge')
    if (badge) {
      if (count && count > 0) {
        badge.textContent = count.toLocaleString()
        badge.style.backgroundColor = '#dbeafe'
        badge.style.color = '#1e40af'
      } else {
        badge.textContent = '-'
        badge.style.backgroundColor = '#e5e7eb'
        badge.style.color = '#374151'
      }
    }
  }

  async loadAutocompleteData(runId = null) {
    console.log('GeneManager: loadAutocompleteData called, runId:', runId)
    if (!this.projectIdentifier) {
      console.warn('GeneManager: No project identifier found')
      return
    }

    try {
      // Try run-specific file first if run_id is provided
      let url = null
      let data = null

      if (runId) {
        url = `/projects/${encodeURIComponent(this.projectIdentifier)}/get_file?filename=autocomplete_genes.json&step=cell_filtering&run_id=${encodeURIComponent(runId)}&display=true`
        console.log('GeneManager: Attempting to load run-specific file:', url)
        try {
          const response = await fetch(url)
          console.log('GeneManager: Run-specific response status:', response.status, 'ok:', response.ok)
          if (response.ok) {
            const contentType = response.headers.get('content-type')
            console.log('GeneManager: Run-specific content-type:', contentType)
            if (contentType && contentType.includes('application/json')) {
              data = await response.json()
              console.log('GeneManager: Run-specific data loaded, has search:', !!data.search, 'search length:', data.search?.length)
            } else {
              console.warn('GeneManager: Run-specific response is not JSON, content-type:', contentType)
            }
          } else {
            console.warn('GeneManager: Run-specific response not OK, status:', response.status)
          }
        } catch (e) {
          console.warn('GeneManager: Failed to load run-specific autocomplete file:', e)
        }
      }

      // Fall back to parsing directory file if run-specific file not found
      if (!data || !data.search) {
        url = `/projects/${encodeURIComponent(this.projectIdentifier)}/get_file?filename=autocomplete_genes.json&step=parsing&display=true`
        console.log('GeneManager: Attempting to load parsing file:', url)
        try {
          const response = await fetch(url, {
            method: 'GET',
            credentials: 'same-origin',
            headers: {
              'Accept': 'application/json'
            }
          })
          console.log('GeneManager: Parsing response status:', response.status, 'ok:', response.ok)
          if (response.ok) {
            const contentType = response.headers.get('content-type')
            console.log('GeneManager: Parsing content-type:', contentType)
            
            // Try to parse as JSON first
            try {
              data = await response.json()
              console.log('GeneManager: Parsing data loaded as JSON, has search:', !!data.search, 'search length:', data.search?.length)
            } catch (jsonError) {
              // If JSON parsing fails, try as text
              console.warn('GeneManager: Failed to parse as JSON, trying as text:', jsonError)
              const text = await response.text()
              console.log('GeneManager: Parsing response text (first 500 chars):', text.substring(0, 500))
              
              // Try to parse the text as JSON
              try {
                data = JSON.parse(text)
                console.log('GeneManager: Successfully parsed text as JSON')
              } catch (parseError) {
                console.error('GeneManager: Failed to parse response text as JSON:', parseError)
              }
            }
            
            // Check if content-type was not JSON but we got JSON data
            if (!contentType || !contentType.includes('application/json')) {
              if (data && typeof data === 'object') {
                console.warn('GeneManager: Got JSON data but content-type was:', contentType, '- proceeding anyway')
              }
            }
          } else {
            console.warn('GeneManager: Parsing response not OK, status:', response.status, response.statusText)
            try {
              const errorText = await response.text()
              console.log('GeneManager: Parsing error response (first 500 chars):', errorText.substring(0, 500))
            } catch (textError) {
              console.error('GeneManager: Could not read error response text:', textError)
            }
          }
        } catch (e) {
          console.error('GeneManager: Exception loading parsing autocomplete file:', e)
          console.error('GeneManager: Exception name:', e.name)
          console.error('GeneManager: Exception message:', e.message)
          console.error('GeneManager: Exception stack:', e.stack)
        }
      }

      if (data && data.search) {
        this.autocompleteData = data.search
        const geneCount = this.autocompleteData.length
        console.log(`GeneManager: Successfully loaded ${geneCount} genes for autocomplete`)
        console.log('GeneManager: First 3 entries:', this.autocompleteData.slice(0, 3))
        // Update the gene count badge
        this.updateGeneCountBadge(geneCount)
      } else {
        console.warn('GeneManager: Failed to load autocomplete data - data:', data, 'has search:', !!data?.search)
        this.autocompleteData = []
        this.updateGeneCountBadge(0)
      }
    } catch (error) {
      console.error('GeneManager: Error loading autocomplete data:', error)
      console.error('GeneManager: Error stack:', error.stack)
      this.autocompleteData = []
      this.updateGeneCountBadge(0)
    }
  }

  handleInput(query) {
    console.log('GeneManager: handleInput called with query:', query)
    if (!query || query.trim().length === 0) {
      console.log('GeneManager: Empty query, hiding dropdown')
      this.hideDropdown()
      return
    }

    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      console.warn('GeneManager: No autocomplete data available, length:', this.autocompleteData?.length)
      return
    }

    console.log('GeneManager: Searching in', this.autocompleteData.length, 'entries')
    const searchTerm = query.toLowerCase().trim()
    this.currentMatches = this.autocompleteData
      .filter(entry => {
        // Parse entry: "gene_symbol FBgn0000000 {stable_id}"
        const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
        if (!match) {
          console.warn('GeneManager: Entry does not match pattern:', entry.substring(0, 50))
          return false
        }
        
        const [, geneSymbol, ensemblId, stableId] = match
        const searchLower = searchTerm.toLowerCase()
        
        const matches = geneSymbol.toLowerCase().includes(searchLower) ||
               ensemblId.toLowerCase().includes(searchLower) ||
               stableId.includes(searchTerm)
        
        return matches
      })
      .slice(0, 10) // Limit to 10 results

    console.log('GeneManager: Found', this.currentMatches.length, 'matches for query:', searchTerm)
    if (this.currentMatches.length > 0) {
      console.log('GeneManager: First match:', this.currentMatches[0])
      this.renderDropdown()
      this.showDropdown()
    } else {
      console.log('GeneManager: No matches found, hiding dropdown')
      this.hideDropdown()
    }
  }

  renderDropdown() {
    console.log('GeneManager: renderDropdown called with', this.currentMatches.length, 'matches')
    const dropdown = document.getElementById('gene-autocomplete-dropdown')
    if (!dropdown) {
      console.error('GeneManager: Dropdown element not found! ID: gene-autocomplete-dropdown')
      return
    }

    dropdown.innerHTML = ''

    this.currentMatches.forEach((entry, index) => {
      const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
      if (!match) return

      const [, geneSymbol, ensemblId, stableId] = match
      const item = document.createElement('div')
      item.style.cssText = 'padding: 10px 12px; cursor: pointer; border-bottom: 1px solid #f3f4f6; transition: background-color 0.15s;'
      item.innerHTML = `
        <div style="font-weight: 500; color: #111827; font-size: 14px;">${geneSymbol}</div>
        <div style="font-size: 12px; color: #6b7280; margin-top: 2px;">${ensemblId} | Stable ID: ${stableId}</div>
      `
      
      item.addEventListener('mouseenter', () => {
        item.style.backgroundColor = '#f3f4f6'
      })
      item.addEventListener('mouseleave', () => {
        item.style.backgroundColor = 'white'
      })

      item.addEventListener('click', () => {
        this.selectGene(entry)
      })

      dropdown.appendChild(item)
    })

    if (this.currentMatches.length === 0) {
      const noResults = document.createElement('div')
      noResults.style.cssText = 'padding: 10px 12px; color: #6b7280; font-size: 14px;'
      noResults.textContent = 'No genes found'
      dropdown.appendChild(noResults)
    }
  }

  showDropdown() {
    const dropdown = document.getElementById('gene-autocomplete-dropdown')
    if (dropdown) {
      dropdown.style.display = 'block'
      console.log('GeneManager: Dropdown shown')
    } else {
      console.error('GeneManager: Cannot show dropdown - element not found')
    }
  }

  hideDropdown() {
    const dropdown = document.getElementById('gene-autocomplete-dropdown')
    if (dropdown) {
      dropdown.style.display = 'none'
      console.log('GeneManager: Dropdown hidden')
    } else {
      console.error('GeneManager: Cannot hide dropdown - element not found')
    }
  }

  selectGene(entry) {
    // Parse the entry to extract gene information
    const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
    if (!match) {
      console.error('GeneManager: Invalid gene entry format:', entry)
      return
    }

    const [, geneSymbol, ensemblId, stableId] = match
    
    const gene = {
      symbol: geneSymbol,
      ensemblId: ensemblId,
      stableId: parseInt(stableId),
      query: geneSymbol
    }

    // Add to tags if not already present
    const existingIndex = this.geneTags.findIndex(g => g.stableId === gene.stableId)
    if (existingIndex === -1) {
      this.geneTags.push(gene)
      this.renderGeneTags()
      this.processAllGenes()
    }

    // Clear input
    const input = document.getElementById('gene-autocomplete-input')
    if (input) {
      input.value = ''
    }

    this.hideDropdown()
  }

  renderGeneTags() {
    const container = document.getElementById('gene-tags-container')
    const input = document.getElementById('gene-autocomplete-input')
    if (!container || !input) return

    // Store current input value and cursor position
    const inputValue = input.value
    const cursorPos = input.selectionStart

    // Clear only tags, keep input
    const existingTags = container.querySelectorAll('.gene-tag')
    existingTags.forEach(tag => tag.remove())

    // Remove input temporarily to reorder
    const inputWasInContainer = input.parentElement === container
    if (inputWasInContainer) {
      container.removeChild(input)
    }

    // Add tags first
    this.geneTags.forEach((gene, index) => {
      const tag = document.createElement('div')
      tag.className = 'gene-tag'
      tag.style.cssText = 'display: inline-flex; align-items: center; gap: 6px; padding: 6px 10px; background-color: #dbeafe; color: #1e40af; border-radius: 16px; font-size: 13px; font-weight: 500;'
      tag.innerHTML = `
        <span>${gene.symbol}</span>
        <button data-gene-index="${index}" 
                style="background: none; border: none; color: #1e40af; cursor: pointer; padding: 0; margin: 0; font-size: 16px; line-height: 1; width: 18px; height: 18px; display: flex; align-items: center; justify-content: center; border-radius: 50%;"
                onmouseover="this.style.backgroundColor='#93c5fd'; this.style.color='#1e3a8a'"
                onmouseout="this.style.backgroundColor=''; this.style.color='#1e40af'">×</button>
      `
      container.appendChild(tag)
      
      // Add click handler for remove button
      const removeBtn = tag.querySelector('button')
      if (removeBtn) {
        removeBtn.addEventListener('click', (e) => {
          e.stopPropagation()
          e.preventDefault()
          this.removeGeneTag(index)
        })
      }
    })

    // Re-add input as last child (flex item) - it should already be in container but ensure it's last
    if (inputWasInContainer) {
      container.appendChild(input)
    } else if (input.parentElement) {
      // Input is somewhere else, move it
      input.parentElement.removeChild(input)
      container.appendChild(input)
    } else {
      // Input not in DOM, add it
      container.appendChild(input)
    }

    // Restore input value and cursor
    input.value = inputValue
    if (cursorPos !== null && inputValue) {
      setTimeout(() => {
        input.setSelectionRange(cursorPos, cursorPos)
      }, 0)
    }
  }

  removeGeneTag(index) {
    if (index >= 0 && index < this.geneTags.length) {
      this.geneTags.splice(index, 1)
      this.renderGeneTags()
      this.processAllGenes()
    }
  }

  processGeneInput(query) {
    if (!query || !query.trim()) return

    // Wait for autocomplete data if needed
    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      console.log('GeneManager: Waiting for autocomplete data...')
      setTimeout(() => {
        this.processGeneInput(query)
      }, 500)
      return
    }

    const matched = this.findGeneInAutocomplete(query.trim())
    if (matched) {
      // Check if already in tags
      const existingIndex = this.geneTags.findIndex(g => g.stableId === matched.stableId)
      if (existingIndex === -1) {
        this.geneTags.push(matched)
        this.renderGeneTags()
        // Process all genes after a short delay to batch updates
        setTimeout(() => {
          this.processAllGenes()
        }, 100)
      }
    } else {
      // Gene not found - remove from notFoundQueries if it was there, but don't add it
      // The query is simply ignored/deleted
      console.log('GeneManager: Gene not found:', query)
    }
  }

  async processAllGenes() {
    if (this.geneTags.length === 0) {
      // Clear results if no genes
      const resultsDiv = document.getElementById('gene-expression-results')
      const summaryDiv = document.getElementById('gene-results-summary')
      if (resultsDiv) resultsDiv.innerHTML = ''
      if (summaryDiv) summaryDiv.style.display = 'none'
      return
    }

    const summaryDiv = document.getElementById('gene-results-summary')
    const statsDiv = document.getElementById('gene-results-stats')
    const notFoundLinkDiv = document.getElementById('gene-not-found-link')
    const resultsDiv = document.getElementById('gene-expression-results')

    if (!summaryDiv || !statsDiv || !resultsDiv) return

    // Update summary
    statsDiv.innerHTML = `
      <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
        <span style="color: #059669; font-weight: 500;">✓ Found: ${this.geneTags.length}</span>
      </div>
    `

    notFoundLinkDiv.style.display = 'none'
    summaryDiv.style.display = 'block'

    // Clear and display results
    resultsDiv.innerHTML = ''

    // Display all genes and load their expression data
    for (const gene of this.geneTags) {
      this.displayBulkGene(gene, resultsDiv)
    }

    // Load expression data for all genes
    for (const gene of this.geneTags) {
      await this.loadGeneExpressionData(gene, resultsDiv)
    }
  }

  displayGeneInfo(gene) {
    const resultsDiv = document.getElementById('gene-expression-results')
    if (!resultsDiv) return

    resultsDiv.innerHTML = `
      <div style="padding: 16px; background-color: #f9fafb; border-radius: 6px; border: 1px solid #e5e7eb;">
        <div style="margin-bottom: 12px;">
          <h3 style="margin: 0; font-size: 16px; font-weight: 600; color: #111827;">${gene.symbol}</h3>
          <div style="margin-top: 4px; font-size: 12px; color: #6b7280;">
            ${gene.ensemblId} | Stable ID: ${gene.stableId}
          </div>
        </div>
        <div id="gene-expression-loading" style="color: #6b7280; font-size: 14px;">Loading expression data...</div>
        <div id="gene-expression-data" style="display: none;"></div>
      </div>
    `
  }

  async findGeneIndexesByStableId(stableId) {
    const loadingDiv = document.getElementById('gene-expression-loading')
    const dataDiv = document.getElementById('gene-expression-data')
    
    if (!loadingDiv || !dataDiv) return

    try {
      // Get current loom file from controller
      let loomFile = 'parsing/output.loom'
      try {
        if (this.controller.getCurrentLoomFileForRequest) {
          loomFile = this.controller.getCurrentLoomFileForRequest()
        }
      } catch (e) {
        console.warn('GeneManager: Could not get current loom file, using default:', e.message)
      }

      // Call the gene expression endpoint
      const url = `/projects/${encodeURIComponent(this.projectIdentifier)}/gene_expression.json?stable_id=${encodeURIComponent(stableId)}&loom_file=${encodeURIComponent(loomFile)}`
      
      const response = await fetch(url)
      if (!response.ok) {
        const errorData = await response.json().catch(() => ({ error: 'Unknown error' }))
        throw new Error(errorData.error || `HTTP ${response.status}`)
      }

      const data = await response.json()
      
      if (data.error) {
        throw new Error(data.error)
      }

      // Display the expression data
      loadingDiv.style.display = 'none'
      dataDiv.style.display = 'block'
      
      const expressionValues = data.expression_values || []
      const stats = this.calculateExpressionStats(expressionValues)

      dataDiv.innerHTML = `
        <div style="padding: 12px; background-color: white; border-radius: 4px; border: 1px solid #e5e7eb;">
          <div style="margin-bottom: 12px;">
            <div style="font-size: 13px; font-weight: 500; color: #374151; margin-bottom: 8px;">Expression Statistics</div>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 12px;">
              <div>
                <span style="color: #6b7280;">Cells:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.nCells.toLocaleString()}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Mean:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.mean.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Min:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.min.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Max:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.max.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Median:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.median.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Std Dev:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.stdDev.toFixed(2)}</span>
              </div>
            </div>
          </div>
          <div style="font-size: 11px; color: #6b7280; margin-top: 8px; padding-top: 8px; border-top: 1px solid #e5e7eb;">
            Gene Index: ${data.gene_index} | Stable ID: ${data.stable_id}
          </div>
        </div>
      `
    } catch (error) {
      console.error('GeneManager: Error loading gene expression:', error)
      loadingDiv.style.display = 'none'
      dataDiv.style.display = 'block'
      dataDiv.innerHTML = `
        <div style="padding: 12px; background-color: #fef2f2; border-radius: 4px; border: 1px solid #fecaca; color: #dc2626; font-size: 14px;">
          Error loading expression data: ${error.message}
        </div>
      `
    }
  }

  calculateExpressionStats(values) {
    if (!values || values.length === 0) {
      return {
        nCells: 0,
        mean: 0,
        min: 0,
        max: 0,
        median: 0,
        stdDev: 0
      }
    }

    const numericValues = values.map(v => parseFloat(v)).filter(v => !isNaN(v))
    
    if (numericValues.length === 0) {
      return {
        nCells: values.length,
        mean: 0,
        min: 0,
        max: 0,
        median: 0,
        stdDev: 0
      }
    }

    const sorted = [...numericValues].sort((a, b) => a - b)
    const sum = numericValues.reduce((a, b) => a + b, 0)
    const mean = sum / numericValues.length
    const variance = numericValues.reduce((sum, val) => sum + Math.pow(val - mean, 2), 0) / numericValues.length
    const stdDev = Math.sqrt(variance)
    
    const median = sorted.length % 2 === 0
      ? (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2
      : sorted[Math.floor(sorted.length / 2)]

    return {
      nCells: numericValues.length,
      mean: mean,
      min: sorted[0],
      max: sorted[sorted.length - 1],
      median: median,
      stdDev: stdDev
    }
  }

  parseBulkGeneInput(inputText) {
    // Split by newlines, commas, spaces, or tabs
    const genes = inputText
      .split(/[\n,\s\t]+/)
      .map(g => g.trim())
      .filter(g => g.length > 0)
    
    // Remove duplicates while preserving order
    return [...new Set(genes)]
  }

  findGeneInAutocomplete(query) {
    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      return null
    }

    const searchTerm = query.trim().toLowerCase()
    
    // Try to find exact or partial match
    for (const entry of this.autocompleteData) {
      const match = entry.match(/^(.+?)\s+(FBgn\d+)\s+\{(\d+)\}/)
      if (!match) continue
      
      const [, geneSymbol, ensemblId, stableId] = match
      
      // Check for exact match on symbol, Ensembl ID, or stable ID
      if (geneSymbol.toLowerCase() === searchTerm ||
          ensemblId.toLowerCase() === searchTerm ||
          stableId === searchTerm ||
          geneSymbol.toLowerCase().startsWith(searchTerm) ||
          ensemblId.toLowerCase().startsWith(searchTerm)) {
        return {
          symbol: geneSymbol,
          ensemblId: ensemblId,
          stableId: parseInt(stableId),
          originalQuery: query
        }
      }
    }
    
    return null
  }

  async processBulkGenes() {
    const bulkInput = document.getElementById('bulk-gene-input')
    const summaryDiv = document.getElementById('bulk-gene-summary')
    const statsDiv = document.getElementById('bulk-gene-stats')
    const notFoundLinkDiv = document.getElementById('bulk-gene-not-found-link')
    const resultsDiv = document.getElementById('gene-expression-results')
    
    if (!bulkInput || !summaryDiv || !statsDiv || !resultsDiv) {
      console.error('GeneManager: Required elements not found for bulk processing')
      return
    }

    const inputText = bulkInput.value.trim()
    if (!inputText) {
      alert('Please enter at least one gene symbol or Ensembl ID')
      return
    }

    // Wait for autocomplete data if not loaded yet
    if (!this.autocompleteData || this.autocompleteData.length === 0) {
      console.log('GeneManager: Autocomplete data not loaded, waiting...')
      await this.loadAutocompleteData()
      
      // Try again after a short delay
      await new Promise(resolve => setTimeout(resolve, 500))
    }

    const geneQueries = this.parseBulkGeneInput(inputText)
    console.log('GeneManager: Processing', geneQueries.length, 'genes:', geneQueries)

    // Match genes
    this.processedGenes = []
    this.notFoundGenes = []
    
    for (const query of geneQueries) {
      const matched = this.findGeneInAutocomplete(query)
      if (matched) {
        this.processedGenes.push(matched)
      } else {
        this.notFoundGenes.push(query)
      }
    }

    // Display summary
    const foundCount = this.processedGenes.length
    const notFoundCount = this.notFoundGenes.length
    const totalCount = geneQueries.length

    statsDiv.innerHTML = `
      <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
        <span style="color: #059669; font-weight: 500;">✓ Found: ${foundCount}</span>
        <span style="color: #dc2626; font-weight: 500;">✗ Not Found: ${notFoundCount}</span>
        <span style="color: #6b7280;">Total: ${totalCount}</span>
      </div>
    `

    // Show link to view not found genes if any
    if (notFoundCount > 0) {
      const linkId = `show-not-found-${Date.now()}`
      notFoundLinkDiv.style.display = 'block'
      notFoundLinkDiv.innerHTML = `
        <a href="#" id="${linkId}" style="color: #3b82f6; text-decoration: none; font-size: 13px; font-weight: 500;">
          View ${notFoundCount} not found ${notFoundCount === 1 ? 'gene' : 'genes'} →
        </a>
      `
      
      // Add click handler
      setTimeout(() => {
        const link = document.getElementById(linkId)
        if (link) {
          link.addEventListener('click', (e) => {
            e.preventDefault()
            this.showNotFoundGenes()
          })
        }
      }, 100)
    } else {
      notFoundLinkDiv.style.display = 'none'
    }

    summaryDiv.style.display = 'block'

    // Clear and display results for found genes
    resultsDiv.innerHTML = ''
    
    if (foundCount > 0) {
      // Display all found genes
      for (const gene of this.processedGenes) {
        this.displayBulkGene(gene, resultsDiv)
      }
      
      // Load expression data for all found genes
      for (const gene of this.processedGenes) {
        await this.loadGeneExpressionData(gene, resultsDiv)
      }
    } else {
      resultsDiv.innerHTML = `
        <div style="padding: 16px; background-color: #fef2f2; border-radius: 6px; border: 1px solid #fecaca; color: #dc2626; font-size: 14px; text-align: center;">
          No genes were found. Please check your input and try again.
        </div>
      `
    }

    // Scroll to results
    resultsDiv.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }

  displayBulkGene(gene, container) {
    const geneDiv = document.createElement('div')
    geneDiv.id = `gene-result-${gene.stableId}`
    geneDiv.style.cssText = 'margin-bottom: 16px;'
    geneDiv.innerHTML = `
      <div style="padding: 16px; background-color: #f9fafb; border-radius: 6px; border: 1px solid #e5e7eb;">
        <div style="margin-bottom: 12px;">
          <h3 style="margin: 0; font-size: 16px; font-weight: 600; color: #111827;">${gene.symbol}</h3>
          <div style="margin-top: 4px; font-size: 12px; color: #6b7280;">
            ${gene.ensemblId} | Stable ID: ${gene.stableId}
          </div>
        </div>
        <div id="gene-expression-loading-${gene.stableId}" style="color: #6b7280; font-size: 14px;">Loading expression data...</div>
        <div id="gene-expression-data-${gene.stableId}" style="display: none;"></div>
      </div>
    `
    container.appendChild(geneDiv)
  }

  async loadGeneExpressionData(gene, container) {
    const loadingDiv = document.getElementById(`gene-expression-loading-${gene.stableId}`)
    const dataDiv = document.getElementById(`gene-expression-data-${gene.stableId}`)
    
    if (!loadingDiv || !dataDiv) return

    try {
      let loomFile = 'parsing/output.loom'
      try {
        if (this.controller.getCurrentLoomFileForRequest) {
          loomFile = this.controller.getCurrentLoomFileForRequest()
        }
      } catch (e) {
        console.warn('GeneManager: Could not get current loom file, using default:', e.message)
      }

      const url = `/projects/${encodeURIComponent(this.projectIdentifier)}/gene_expression.json?stable_id=${encodeURIComponent(gene.stableId)}&loom_file=${encodeURIComponent(loomFile)}`
      
      const response = await fetch(url)
      if (!response.ok) {
        const errorData = await response.json().catch(() => ({ error: 'Unknown error' }))
        throw new Error(errorData.error || `HTTP ${response.status}`)
      }

      const data = await response.json()
      
      if (data.error) {
        throw new Error(data.error)
      }

      loadingDiv.style.display = 'none'
      dataDiv.style.display = 'block'
      
      const expressionValues = data.expression_values || []
      const stats = this.calculateExpressionStats(expressionValues)

      dataDiv.innerHTML = `
        <div style="padding: 12px; background-color: white; border-radius: 4px; border: 1px solid #e5e7eb;">
          <div style="margin-bottom: 12px;">
            <div style="font-size: 13px; font-weight: 500; color: #374151; margin-bottom: 8px;">Expression Statistics</div>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 12px;">
              <div>
                <span style="color: #6b7280;">Cells:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.nCells.toLocaleString()}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Mean:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.mean.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Min:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.min.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Max:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.max.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Median:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.median.toFixed(2)}</span>
              </div>
              <div>
                <span style="color: #6b7280;">Std Dev:</span>
                <span style="color: #111827; font-weight: 500; margin-left: 4px;">${stats.stdDev.toFixed(2)}</span>
              </div>
            </div>
          </div>
          <div style="font-size: 11px; color: #6b7280; margin-top: 8px; padding-top: 8px; border-top: 1px solid #e5e7eb;">
            Gene Index: ${data.gene_index} | Stable ID: ${data.stable_id}
          </div>
        </div>
      `
    } catch (error) {
      console.error(`GeneManager: Error loading expression data for ${gene.symbol}:`, error)
      loadingDiv.style.display = 'none'
      dataDiv.style.display = 'block'
      dataDiv.innerHTML = `
        <div style="padding: 12px; background-color: #fef2f2; border-radius: 4px; border: 1px solid #fecaca; color: #dc2626; font-size: 14px;">
          Error loading expression data: ${error.message}
        </div>
      `
    }
  }

  showNotFoundGenes() {
    if (this.notFoundGenes.length === 0) {
      return
    }

    // Create a modal-like overlay
    const overlay = document.createElement('div')
    overlay.style.cssText = 'position: fixed; top: 0; left: 0; right: 0; bottom: 0; background-color: rgba(0, 0, 0, 0.5); z-index: 10000; display: flex; align-items: center; justify-content: center; padding: 20px;'
    
    const modal = document.createElement('div')
    modal.style.cssText = 'background: white; border-radius: 8px; padding: 24px; max-width: 500px; width: 100%; max-height: 80vh; overflow-y: auto; box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1);'
    
    modal.innerHTML = `
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
        <h3 style="margin: 0; font-size: 18px; font-weight: 600; color: #111827;">
          Not Found Genes (${this.notFoundGenes.length})
        </h3>
        <button id="close-not-found-modal" style="background: none; border: none; font-size: 24px; color: #6b7280; cursor: pointer; padding: 0; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; border-radius: 4px;" 
                onmouseover="this.style.backgroundColor='#f3f4f6'; this.style.color='#374151'" 
                onmouseout="this.style.backgroundColor=''; this.style.color='#6b7280'">×</button>
      </div>
      <div style="font-size: 14px; color: #6b7280; margin-bottom: 16px;">
        The following gene${this.notFoundGenes.length === 1 ? '' : 's'} could not be found in the dataset:
      </div>
      <div style="background-color: #f9fafb; border: 1px solid #e5e7eb; border-radius: 6px; padding: 12px; max-height: 400px; overflow-y: auto;">
        <div style="font-family: monospace; font-size: 13px; color: #374151; line-height: 1.8;">
          ${this.notFoundGenes.map(gene => gene).join('<br>')}
        </div>
      </div>
      <div style="margin-top: 16px; display: flex; justify-content: flex-end;">
        <button id="copy-not-found-genes" style="padding: 8px 16px; background-color: #3b82f6; color: white; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; margin-right: 8px;"
                onmouseover="this.style.backgroundColor='#2563eb'"
                onmouseout="this.style.backgroundColor='#3b82f6'">
          Copy to Clipboard
        </button>
        <button id="close-not-found-btn" style="padding: 8px 16px; background-color: #e5e7eb; color: #374151; border: none; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer;"
                onmouseover="this.style.backgroundColor='#d1d5db'"
                onmouseout="this.style.backgroundColor='#e5e7eb'">
          Close
        </button>
      </div>
    `
    
    overlay.appendChild(modal)
    document.body.appendChild(overlay)
    
    // Close handlers
    const closeModal = () => {
      document.body.removeChild(overlay)
    }
    
    document.getElementById('close-not-found-modal').addEventListener('click', closeModal)
    document.getElementById('close-not-found-btn').addEventListener('click', closeModal)
    overlay.addEventListener('click', (e) => {
      if (e.target === overlay) {
        closeModal()
      }
    })
    
    // Copy to clipboard
    document.getElementById('copy-not-found-genes').addEventListener('click', () => {
      const geneList = this.notFoundGenes.join('\n')
      navigator.clipboard.writeText(geneList).then(() => {
        const btn = document.getElementById('copy-not-found-genes')
        const originalText = btn.textContent
        btn.textContent = 'Copied!'
        btn.style.backgroundColor = '#059669'
        setTimeout(() => {
          btn.textContent = originalText
          btn.style.backgroundColor = '#3b82f6'
        }, 2000)
      }).catch(err => {
        console.error('Failed to copy:', err)
        alert('Failed to copy to clipboard')
      })
    })
  }

}

