// DownloadManager - Handles all data export functionality
export class DownloadManager {
  constructor(controller) {
    this.controller = controller
  }

  // Download global distribution for all categories
  async downloadGlobalDistribution(event) {
    event.stopPropagation()
    
    const button = event.currentTarget
    const metadataId = parseInt(button.dataset.metadataId)
    
    // Get the displayed metadata vector
    const displayedMetadataVector = this.controller.dataManager.getMetadataVectorById(metadataId)
    if (!displayedMetadataVector || !displayedMetadataVector.values || displayedMetadataVector.data_type !== 'DISCRETE') {
      console.warn('Cannot download: metadata must be categorical')
      return
    }
    
    // Get filtered cell indices (if any filters are active)
    const filteredIndices = this.controller.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const hasFilters = filteredSet !== null
    
    // Get all unique categories and count them (total and filtered)
    const uniqueCategories = [...new Set(displayedMetadataVector.values)]
    const totalCategoryCounts = {}
    const filteredCategoryCounts = {}
    
    displayedMetadataVector.values.forEach((cat, idx) => {
      totalCategoryCounts[cat] = (totalCategoryCounts[cat] || 0) + 1
      if (!hasFilters || filteredSet.has(idx)) {
        filteredCategoryCounts[cat] = (filteredCategoryCounts[cat] || 0) + 1
      }
    })
    
    // Sort categories by filtered count (or total if no filters)
    const sortedCategories = uniqueCategories.sort((a, b) => {
      const countA = hasFilters ? (filteredCategoryCounts[a] || 0) : (totalCategoryCounts[a] || 0)
      const countB = hasFilters ? (filteredCategoryCounts[b] || 0) : (totalCategoryCounts[b] || 0)
      return countB - countA
    })
    
    // Load SheetJS library
    if (!window.XLSX) {
      try {
        await this.loadSheetJS()
      } catch (error) {
        console.warn('Could not load Excel library')
        return
      }
    }
    
    const wb = window.XLSX.utils.book_new()
    const totalCells = displayedMetadataVector.values.length
    const filteredTotalCells = hasFilters ? filteredSet.size : totalCells
    
    // Sheet 0: Active Filters (if filters exist)
    if (hasFilters) {
      this.addFiltersSheet(wb)
    }
    
    // Sheet 1 (or 2 if filters exist): Category Summary (with total and filtered counts)
    const metadataLabel = displayedMetadataVector.name || 'Category'
    const summaryData = hasFilters 
      ? [[metadataLabel, 'Total Cells', 'Total %', 'Filtered Cells', 'Filtered %']]
      : [[metadataLabel, 'Cell Count', 'Percentage']]
    
    sortedCategories.forEach(category => {
      const totalCount = totalCategoryCounts[category] || 0
      const totalPercentage = parseFloat(((totalCount / totalCells) * 100).toFixed(2))
      
      if (hasFilters) {
        const filteredCount = filteredCategoryCounts[category] || 0
        const filteredPercentage = filteredTotalCells > 0 
          ? parseFloat(((filteredCount / filteredTotalCells) * 100).toFixed(2)) 
          : 0
        summaryData.push([category, totalCount, totalPercentage, filteredCount, filteredPercentage])
      } else {
        summaryData.push([category, totalCount, totalPercentage])
      }
    })
    const ws1 = window.XLSX.utils.aoa_to_sheet(summaryData)
    window.XLSX.utils.book_append_sheet(wb, ws1, 'Categories')
    
    // Check if there's active coloring
    const coloringMetadataVector = this.controller.currentMetadataVector
    if (coloringMetadataVector && coloringMetadataVector.values) {
      if (coloringMetadataVector.data_type === 'DISCRETE') {
        // Sheet 2: Categorical Distribution
        await this.addCategoricalDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
      } else if (coloringMetadataVector.data_type === 'NUMERIC') {
        // Sheet 2: Continuous Distribution (bins)
        await this.addContinuousDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
        // Sheet 3: Summary statistics for each category
        await this.addContinuousSummarySheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
      }
    }
    
    // Create filename with filter checksum
    const projectKey = this.getProjectKey()
    const displayedMetadataName = this.sanitizeFilename(displayedMetadataVector.name || 'metadata')
    const coloringSuffix = coloringMetadataVector 
      ? `_colored-by_${this.sanitizeFilename(coloringMetadataVector.name)}` 
      : ''
    
    // Add checksum if filters are active
    const filterChecksum = hasFilters ? `_${this.calculateFilterChecksum()}` : ''
    const filename = `${projectKey}_${displayedMetadataName}_all-categories${coloringSuffix}${filterChecksum}.xlsx`
    
    // Write and download
    window.XLSX.writeFile(wb, filename, { cellStyles: true })
    
    // console.log(`Downloaded global distribution for ${displayedMetadataVector.name}`)
  }
  
  // Add filters sheet to workbook
  addFiltersSheet(wb) {
    const filtersData = [['Filter Type', 'Metadata', 'Filter Details']]
    
    // Add categorical filters
    if (this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0) {
      for (const [metadataId, selectedCats] of Object.entries(this.controller.selectedCategories)) {
        if (selectedCats && selectedCats.size > 0) {
          const metadataVector = this.controller.dataManager.getMetadataVectorById(parseInt(metadataId))
          if (metadataVector) {
            const metadataName = metadataVector.name || `Metadata ${metadataId}`
            const allCategories = [...new Set(metadataVector.values)]
            
            // Only add if not all categories are selected (i.e., it's actually filtering)
            if (selectedCats.size < allCategories.length) {
              const selectedList = [...selectedCats].join(', ')
              const unselectedCategories = allCategories.filter(category => !selectedCats.has(category))
              const unselectedList = unselectedCategories.join(', ')
              
              const selectedDetail = `Selected (${selectedCats.size}/${allCategories.length}): ${selectedList || 'none'}`
              const unselectedDetail = `Unselected (${unselectedCategories.length}/${allCategories.length}): ${unselectedList || 'none'}`
              
              filtersData.push(['Categorical', metadataName, selectedDetail])
              filtersData.push(['', '', unselectedDetail])
            }
          }
        }
      }
    }
    
    // Add continuous (range) filters
    if (this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0) {
      for (const [metadataId, range] of Object.entries(this.controller.selectedRanges)) {
        if (range && range.min !== undefined && range.max !== undefined) {
          // Check if this filter is disabled
          if (this.controller.disabledFilters && this.controller.disabledFilters.has(parseInt(metadataId))) {
            continue // Skip disabled filters
          }
          
          const metadataVector = this.controller.dataManager.getMetadataVectorById(parseInt(metadataId))
          if (metadataVector) {
            const metadataName = metadataVector.name || `Metadata ${metadataId}`
            const values = metadataVector.values.filter(v => v !== null && v !== undefined && !isNaN(v))
            
            if (values.length === 0) {
              continue
            }
            
            let globalMin = Infinity
            let globalMax = -Infinity
            values.forEach(value => {
              if (value < globalMin) globalMin = value
              if (value > globalMax) globalMax = value
            })
            
            // Check if it's a subrange (not the full range)
            const isFullRange = (Math.abs(range.min - globalMin) < 0.0001 && Math.abs(range.max - globalMax) < 0.0001)
            if (!isFullRange) {
              const filterDetail = `Range: ${range.min.toFixed(4)} to ${range.max.toFixed(4)} (full range: ${globalMin.toFixed(4)} to ${globalMax.toFixed(4)})`
              filtersData.push(['Continuous', metadataName, filterDetail])
            }
          }
        }
      }
    }
    
    // Only add the sheet if there are actual filters (more than just the header row)
    if (filtersData.length > 1) {
      const ws = window.XLSX.utils.aoa_to_sheet(filtersData)
      
      window.XLSX.utils.book_append_sheet(wb, ws, 'Active Filters')
    }
  }
  
  // Add categorical distribution sheet to workbook
  async addCategoricalDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet) {
    // Get coloring categories (from filtered cells only)
    const coloringCategoryCounts = {}
    coloringMetadataVector.values.forEach((cat, idx) => {
      if (!filteredSet || filteredSet.has(idx)) {
        coloringCategoryCounts[cat] = (coloringCategoryCounts[cat] || 0) + 1
      }
    })
    const sortedColoringCategories = Object.keys(coloringCategoryCounts).sort((a, b) => {
      return (coloringCategoryCounts[b] || 0) - (coloringCategoryCounts[a] || 0)
    })
    
    // Create distribution data for counts and percentages separately
    const displayedLabel = displayedMetadataVector.name || 'Category'
    const coloringLabel = coloringMetadataVector.name || 'Coloring'
    const columnHeader = `${displayedLabel} \\ ${coloringLabel}`
    const distributionCountsData = [[columnHeader, ...sortedColoringCategories.map(cat => `${cat} (# cells)`)]]
    const distributionPercentagesData = [[columnHeader, ...sortedColoringCategories.map(cat => `${cat} (% cells)`)]]
    
    sortedCategories.forEach(displayedCategory => {
      // Find cells in this category (filtered only)
      const cellsInCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInCategory.push(i)
        }
      }
      
      // Count distribution
      const distribution = {}
      cellsInCategory.forEach(cellIndex => {
        const coloringCat = coloringMetadataVector.values[cellIndex]
        distribution[coloringCat] = (distribution[coloringCat] || 0) + 1
      })
      
      // Add counts
      const countsRow = [displayedCategory]
      sortedColoringCategories.forEach(coloringCat => {
        countsRow.push(distribution[coloringCat] || 0)
      })
      distributionCountsData.push(countsRow)
      
      // Add percentages
      const percentagesRow = [displayedCategory]
      sortedColoringCategories.forEach(coloringCat => {
        const count = distribution[coloringCat] || 0
        const percentage = cellsInCategory.length > 0 ? parseFloat(((count / cellsInCategory.length) * 100).toFixed(2)) : 0
        percentagesRow.push(percentage)
      })
      distributionPercentagesData.push(percentagesRow)
    })
    
    const countsSheet = window.XLSX.utils.aoa_to_sheet(distributionCountsData)
    window.XLSX.utils.book_append_sheet(wb, countsSheet, 'Distribution (# cells)')
    
    const percentagesSheet = window.XLSX.utils.aoa_to_sheet(distributionPercentagesData)
    window.XLSX.utils.book_append_sheet(wb, percentagesSheet, 'Distribution (% cells)')
  }
  
  // Add continuous distribution sheet to workbook
  async addContinuousDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet) {
    // Get global min/max (from filtered cells only)
    const filteredValues = coloringMetadataVector.values.filter((v, idx) => {
      return v !== null && v !== undefined && !isNaN(v) && (!filteredSet || filteredSet.has(idx))
    })
    const globalMin = this.controller.dataManager.safeMin(filteredValues)
    const globalMax = this.controller.dataManager.safeMax(filteredValues)
    if (!Number.isFinite(globalMin) || !Number.isFinite(globalMax)) {
      return
    }
    const numBins = 20
    const binWidth = (globalMax - globalMin) / numBins
    
    // Create bin ranges header
    const binRanges = []
    for (let i = 0; i < numBins; i++) {
      const start = globalMin + i * binWidth
      const end = globalMin + (i + 1) * binWidth
      binRanges.push(`${start.toFixed(2)}-${end.toFixed(2)}`)
    }
    
    const distributionData = [['Category', ...binRanges.map(r => `${r} (count)`), ...binRanges.map(r => `${r} (%)`)]]
    
    sortedCategories.forEach(displayedCategory => {
      const row = [displayedCategory]
      
      // Find cells in this category (filtered only)
      const cellsInCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInCategory.push(i)
        }
      }
      
      // Get values and create bins
      const values = cellsInCategory.map(idx => coloringMetadataVector.values[idx])
      const validValues = values.filter(v => v !== null && v !== undefined && !isNaN(v))
      const bins = Array(numBins).fill(0)
      
      validValues.forEach(value => {
        const binIndex = Math.min(Math.floor((value - globalMin) / binWidth), numBins - 1)
        bins[binIndex]++
      })
      
      // Add counts
      bins.forEach(count => row.push(count))
      
      // Add percentages
      bins.forEach(count => {
        const percentage = validValues.length > 0 ? parseFloat(((count / validValues.length) * 100).toFixed(2)) : 0
        row.push(percentage)
      })
      
      distributionData.push(row)
    })
    
    const ws = window.XLSX.utils.aoa_to_sheet(distributionData)
    window.XLSX.utils.book_append_sheet(wb, ws, 'Distribution')
  }
  
  // Add continuous summary statistics sheet to workbook
  async addContinuousSummarySheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet) {
    const summaryData = [['Category', 'Cell Count', 'Min', 'Max', 'Mean', 'Median', 'Q1', 'Q3', 'Std Dev']]
    
    sortedCategories.forEach(displayedCategory => {
      // Find cells in this category (filtered only)
      const cellsInCategory = []
      for (let i = 0; i < displayedMetadataVector.values.length; i++) {
        if (displayedMetadataVector.values[i] === displayedCategory && (!filteredSet || filteredSet.has(i))) {
          cellsInCategory.push(i)
        }
      }
      
      // Get values
      const values = cellsInCategory.map(idx => coloringMetadataVector.values[idx])
      const validValues = values.filter(v => v !== null && v !== undefined && !isNaN(v))
      
      if (validValues.length === 0) {
        summaryData.push([displayedCategory, 0, 0, 0, 0, 0, 0, 0, 0])
        return
      }
      
      // Calculate statistics
      const min = this.controller.dataManager.safeMin(validValues)
      const max = this.controller.dataManager.safeMax(validValues)
      const mean = validValues.reduce((a, b) => a + b, 0) / validValues.length
      const sortedValues = [...validValues].sort((a, b) => a - b)
      const median = sortedValues[Math.floor(sortedValues.length / 2)]
      const q1 = sortedValues[Math.floor(sortedValues.length * 0.25)]
      const q3 = sortedValues[Math.floor(sortedValues.length * 0.75)]
      const stdDev = Math.sqrt(validValues.reduce((sum, val) => sum + Math.pow(val - mean, 2), 0) / validValues.length)
      
      summaryData.push([
        displayedCategory,
        validValues.length,
        parseFloat(min.toFixed(4)),
        parseFloat(max.toFixed(4)),
        parseFloat(mean.toFixed(4)),
        parseFloat(median.toFixed(4)),
        parseFloat(q1.toFixed(4)),
        parseFloat(q3.toFixed(4)),
        parseFloat(stdDev.toFixed(4))
      ])
    })
    
    const ws = window.XLSX.utils.aoa_to_sheet(summaryData)
    window.XLSX.utils.book_append_sheet(wb, ws, 'Summary Stats')
  }
  
  // Load SheetJS library dynamically
  async loadSheetJS() {
    return new Promise((resolve, reject) => {
      if (window.XLSX) {
        resolve()
        return
      }
      
      const script = document.createElement('script')
      script.src = 'https://cdn.sheetjs.com/xlsx-0.20.1/package/dist/xlsx.full.min.js'
      script.onload = () => resolve()
      script.onerror = () => reject(new Error('Failed to load SheetJS'))
      document.head.appendChild(script)
    })
  }
  
  // Get project key from URL
  getProjectKey() {
    // Try to extract project key from URL path (e.g., /projects/PROJECT_KEY/...)
    const pathParts = window.location.pathname.split('/')
    const projectsIndex = pathParts.indexOf('projects')
    
    if (projectsIndex !== -1 && pathParts.length > projectsIndex + 1) {
      return pathParts[projectsIndex + 1]
    }
    
    return 'project'
  }
  
  // Sanitize filename
  sanitizeFilename(name) {
    return name
      .replace(/[^a-z0-9_\-]/gi, '_')
      .replace(/_+/g, '_')
      .replace(/^_|_$/g, '')
      .toLowerCase()
  }
  
  // Calculate a checksum/hash for the current filters
  calculateFilterChecksum() {
    const filterData = []
    
    // Add categorical filters
    if (this.controller.selectedCategories && Object.keys(this.controller.selectedCategories).length > 0) {
      for (const [metadataId, selectedCats] of Object.entries(this.controller.selectedCategories)) {
        if (selectedCats && selectedCats.size > 0) {
          const metadataVector = this.controller.dataManager.getMetadataVectorById(parseInt(metadataId))
          if (metadataVector) {
            const allCategories = [...new Set(metadataVector.values)]
            // Only include if not all categories are selected
            if (selectedCats.size < allCategories.length) {
              const sortedCategories = [...selectedCats].sort()
              filterData.push(`cat_${metadataId}_${sortedCategories.join(',')}`)
            }
          }
        }
      }
    }
    
    // Add continuous (range) filters
    if (this.controller.selectedRanges && Object.keys(this.controller.selectedRanges).length > 0) {
      for (const [metadataId, range] of Object.entries(this.controller.selectedRanges)) {
        if (range && range.min !== undefined && range.max !== undefined) {
          // Skip disabled filters
          if (this.controller.disabledFilters && this.controller.disabledFilters.has(parseInt(metadataId))) {
            continue
          }
          
          const metadataVector = this.controller.dataManager.getMetadataVectorById(parseInt(metadataId))
          if (metadataVector) {
            const values = metadataVector.values.filter(v => v !== null && v !== undefined && !isNaN(v))
            if (values.length === 0) {
              continue
            }
            
            let globalMin = Infinity
            let globalMax = -Infinity
            values.forEach(value => {
              if (value < globalMin) globalMin = value
              if (value > globalMax) globalMax = value
            })
            
            // Only include if it's a subrange
            const isFullRange = (Math.abs(range.min - globalMin) < 0.0001 && Math.abs(range.max - globalMax) < 0.0001)
            if (!isFullRange) {
              filterData.push(`cont_${metadataId}_${range.min.toFixed(4)}_${range.max.toFixed(4)}`)
            }
          }
        }
      }
    }
    
    // If no filters, return empty string
    if (filterData.length === 0) {
      return ''
    }
    
    // Sort for consistency
    filterData.sort()
    
    // Create a simple hash (using a basic hash function)
    const filterString = filterData.join('|')
    let hash = 0
    for (let i = 0; i < filterString.length; i++) {
      const char = filterString.charCodeAt(i)
      hash = ((hash << 5) - hash) + char
      hash = hash & hash // Convert to 32-bit integer
    }
    
    // Convert to hex and take first 8 characters
    const hashHex = Math.abs(hash).toString(16).padStart(8, '0').substring(0, 8)
    return hashHex
  }
}

