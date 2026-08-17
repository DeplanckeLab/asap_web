// DownloadManager - Handles all data export functionality
export class DownloadManager {
  constructor(controller) {
    this.controller = controller
    this.numContinuousBins = 20
  }

  // Download global distribution for all categories (discrete) or bins (continuous)
  async downloadGlobalDistribution(event) {
    event.stopPropagation()
    this.controller.closeAllDownloadMenus?.()

    const button = event.currentTarget
    const metadataId = parseInt(button.dataset.metadataId)

    const displayedMetadataVector = this.controller.dataManager.getMetadataVectorById(metadataId)
    if (!displayedMetadataVector || !displayedMetadataVector.values) {
      console.warn('Cannot download: metadata values are not loaded')
      return
    }

    if (displayedMetadataVector.data_type === 'DISCRETE') {
      await this.downloadDiscreteSummary(displayedMetadataVector)
      return
    }

    if (displayedMetadataVector.data_type === 'NUMERIC') {
      await this.downloadContinuousSummary(displayedMetadataVector)
      return
    }

    console.warn('Cannot download: unsupported metadata type', displayedMetadataVector.data_type)
  }

  async downloadDiscreteSummary(displayedMetadataVector) {
    const filteredIndices = this.controller.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const hasFilters = filteredSet !== null

    const labels = this.controller.dataManager.getCategoryLabels(displayedMetadataVector)
    if (!labels) {
      throw new Error(`Discrete metadata ${displayedMetadataVector.id} is missing compression_info.categories`)
    }
    const uniqueCategories = labels.map((label) => String(label))
    const totalCategoryCounts = {}
    const filteredCategoryCounts = {}

    const values = displayedMetadataVector.values
    for (let idx = 0; idx < values.length; idx++) {
      const cat = String(labels[values[idx]])
      totalCategoryCounts[cat] = (totalCategoryCounts[cat] || 0) + 1
      if (!hasFilters || filteredSet.has(idx)) {
        filteredCategoryCounts[cat] = (filteredCategoryCounts[cat] || 0) + 1
      }
    }

    const sortedCategories = [...uniqueCategories].sort((a, b) => {
      const countA = hasFilters ? (filteredCategoryCounts[a] || 0) : (totalCategoryCounts[a] || 0)
      const countB = hasFilters ? (filteredCategoryCounts[b] || 0) : (totalCategoryCounts[b] || 0)
      return countB - countA
    })

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

    if (hasFilters) {
      this.addFiltersSheet(wb)
    }

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

    const coloringMetadataVector = this.controller.currentMetadataVector
    if (coloringMetadataVector && coloringMetadataVector.values) {
      if (coloringMetadataVector.data_type === 'DISCRETE') {
        await this.addCategoricalDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
      } else if (coloringMetadataVector.data_type === 'NUMERIC') {
        await this.addContinuousDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
        await this.addContinuousSummarySheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet)
      }
    }

    const filename = this.buildSummaryFilename(displayedMetadataVector, coloringMetadataVector, hasFilters, 'all-categories')
    window.XLSX.writeFile(wb, filename, { cellStyles: true })
  }

  async downloadContinuousSummary(displayedMetadataVector) {
    const filteredIndices = this.controller.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const hasFilters = filteredSet !== null

    const binning = this.buildContinuousBins(displayedMetadataVector, filteredSet)
    if (!binning) {
      console.warn('Cannot download: continuous metadata has no finite values')
      return
    }

    const { binLabels, binAssignments, totalBinCounts, filteredBinCounts, globalMin, globalMax } = binning

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

    if (hasFilters) {
      this.addFiltersSheet(wb)
    }

    // Sheet describing the arbitrary bins used in horizontal bar plots
    const binsInfoData = [
      ['Bin Index', 'Bin Label', 'Start', 'End', 'Total Cells', 'Total %', ...(hasFilters ? ['Filtered Cells', 'Filtered %'] : [])]
    ]
    binLabels.forEach((label, i) => {
      const start = globalMin + i * binning.binWidth
      const end = (i === binning.numBins - 1) ? globalMax : (globalMin + (i + 1) * binning.binWidth)
      const totalCount = totalBinCounts[label] || 0
      const totalPercentage = totalCells > 0 ? parseFloat(((totalCount / totalCells) * 100).toFixed(2)) : 0
      const row = [i + 1, label, parseFloat(start.toFixed(6)), parseFloat(end.toFixed(6)), totalCount, totalPercentage]
      if (hasFilters) {
        const filteredCount = filteredBinCounts[label] || 0
        const filteredPercentage = filteredTotalCells > 0
          ? parseFloat(((filteredCount / filteredTotalCells) * 100).toFixed(2))
          : 0
        row.push(filteredCount, filteredPercentage)
      }
      binsInfoData.push(row)
    })
    const binsInfoSheet = window.XLSX.utils.aoa_to_sheet(binsInfoData)
    window.XLSX.utils.book_append_sheet(wb, binsInfoSheet, 'Bins')

    // Pseudo-categorical vector so existing distribution helpers can be reused
    const binnedDisplayedVector = {
      name: displayedMetadataVector.name || 'Bin',
      values: binAssignments,
      data_type: 'DISCRETE'
    }

    const coloringMetadataVector = this.controller.currentMetadataVector
    const hasDistinctColoring = coloringMetadataVector &&
      coloringMetadataVector.values &&
      coloringMetadataVector.id !== displayedMetadataVector.id

    if (hasDistinctColoring) {
      if (coloringMetadataVector.data_type === 'DISCRETE') {
        await this.addCategoricalDistributionSheet(wb, binnedDisplayedVector, coloringMetadataVector, binLabels, filteredSet)
      } else if (coloringMetadataVector.data_type === 'NUMERIC') {
        await this.addContinuousDistributionSheet(wb, binnedDisplayedVector, coloringMetadataVector, binLabels, filteredSet)
        await this.addContinuousSummarySheet(wb, binnedDisplayedVector, coloringMetadataVector, binLabels, filteredSet)
      }
    } else {
      // Overall summary stats for the continuous metadata itself
      await this.addOverallContinuousSummarySheet(wb, displayedMetadataVector, filteredSet, globalMin, globalMax)
    }

    const filename = this.buildSummaryFilename(
      displayedMetadataVector,
      hasDistinctColoring ? coloringMetadataVector : null,
      hasFilters,
      'bins'
    )
    window.XLSX.writeFile(wb, filename, { cellStyles: true })
  }

  // Download raw metadata values as a gzip-compressed TSV, generated on the fly
  async downloadRawMetadata(event) {
    event.stopPropagation()
    this.controller.closeAllDownloadMenus?.()

    const button = event.currentTarget
    const metadataId = parseInt(button.dataset.metadataId)

    const metadataVector = this.controller.dataManager.getMetadataVectorById(metadataId)
    if (!metadataVector || !metadataVector.values) {
      console.warn('Cannot download raw data: metadata values are not loaded')
      return
    }

    if (typeof CompressionStream === 'undefined') {
      console.warn('Cannot download raw data: CompressionStream is not available in this browser')
      return
    }

    const metadataName = metadataVector.name || `metadata_${metadataId}`
    const values = metadataVector.values
    const includeCellBarcode = this.isTranscriptomicsProject()
    let cellBarcodes = null

    if (includeCellBarcode) {
      cellBarcodes = await this.getCellBarcodes(metadataId, values.length)
      if (!cellBarcodes) {
        console.warn('Cannot download raw data: /col_attrs/CellID is required for transcriptomics projects')
        return
      }
    }

    const header = includeCellBarcode
      ? `cell_index\tcell_barcode\t${metadataName}`
      : `cell_index\t${metadataName}`
    const lines = [header]
    const isDiscrete = this.controller.dataManager.isDiscreteMetadata(metadataVector)
    const labels = isDiscrete ? this.controller.dataManager.getCategoryLabels(metadataVector) : null
    if (isDiscrete && !labels) {
      throw new Error(`Discrete metadata ${metadataId} is missing compression_info.categories`)
    }
    for (let i = 0; i < values.length; i++) {
      const value = values[i]
      let cellValue
      if (labels) {
        cellValue = labels[value] == null ? '' : String(labels[value])
      } else {
        cellValue = (value === null || value === undefined) ? '' : String(value)
      }
      if (includeCellBarcode) {
        const barcode = cellBarcodes[i]
        const barcodeValue = (barcode === null || barcode === undefined) ? '' : String(barcode)
        lines.push(`${i}\t${barcodeValue}\t${cellValue}`)
      } else {
        lines.push(`${i}\t${cellValue}`)
      }
    }
    const tsvContent = lines.join('\n')

    const gzipBlob = await this.gzipText(tsvContent)
    const projectKey = this.getProjectKey()
    const sanitizedName = this.sanitizeFilename(metadataName)
    const filename = `${projectKey}_${sanitizedName}_raw.tsv.gz`
    this.triggerBlobDownload(gzipBlob, filename)
  }

  isTranscriptomicsProject() {
    const tag = String(this.controller.projectTypeTagValue || '').toLowerCase()
    return tag === 'sc' || tag === 'bulk' || tag === 'spat' || tag === 'atac' || tag === 'multi'
  }

  async getCellBarcodes(metadataId, expectedLength) {
    const loomFile = this.resolveLoomFileForMetadata(metadataId)
    return this.getCellBarcodesForLoom(loomFile, expectedLength)
  }

  resolveLoomFileForMetadata(metadataId) {
    const button = document.querySelector(
      `button[data-metadata-id="${metadataId}"][data-metadata-loom-file]`
    )
    if (button?.dataset?.metadataLoomFile) {
      return button.dataset.metadataLoomFile
    }
    return this.controller.currentLoomFile || this.controller.defaultLoomFileValue || null
  }

  resolveCellIdAnnotId(loomFile) {
    const byLoom = this.controller.cellIdAnnotIdsByLoomValue || {}
    if (loomFile && byLoom[loomFile]) {
      return byLoom[loomFile]
    }

    console.warn(`No /col_attrs/CellID annot mapped for loom file: ${loomFile || '(unknown)'}`)
    return null
  }

  resolveGeneExpressionContext(event) {
    const button = event.currentTarget
    const geneId = button.dataset.geneId
    const geneManager = this.controller.geneManager
    if (!geneManager || !geneId) {
      console.warn('Cannot download gene expression: gene manager or gene id missing')
      return null
    }

    const expressionData =
      geneManager.geneExpressionData?.[geneId] ||
      geneManager.geneExpressionData?.[String(geneId)] ||
      geneManager.geneExpressionData?.[parseInt(geneId, 10)]

    if (!expressionData?.values || expressionData.values.length === 0) {
      console.warn('Cannot download gene expression: expression values are not loaded')
      return null
    }

    const geneTag = geneManager.geneTags.find(g => String(g.stableId) === String(geneId))
    const geneSymbol = geneTag?.symbol || String(geneId)
    const ensemblId = geneTag?.ensemblId || ''
    const geneMetadataId = button.dataset.layerMetadataId ||
      button.dataset.metadataId ||
      geneManager.getGeneMetadataId?.(geneId, geneManager.currentMatrixAnnotId) ||
      `gene_${geneId}`

    const finiteValues = []
    for (let i = 0; i < expressionData.values.length; i++) {
      const v = expressionData.values[i]
      if (v !== null && v !== undefined && !isNaN(v) && isFinite(v)) {
        finiteValues.push(v)
      }
    }
    const minVal = this.controller.dataManager.safeMin(finiteValues)
    const maxVal = this.controller.dataManager.safeMax(finiteValues)
    if (!Number.isFinite(minVal) || !Number.isFinite(maxVal)) {
      console.warn('Cannot download gene expression: no finite expression values')
      return null
    }

    const expressionVector = {
      id: geneMetadataId,
      name: geneSymbol,
      values: expressionData.values,
      data_type: 'NUMERIC',
      compression_info: {
        min_val: minVal,
        max_val: maxVal,
        data_type: 'NUMERIC'
      }
    }

    return {
      geneId,
      geneSymbol,
      ensemblId,
      geneMetadataId,
      expressionData,
      expressionVector
    }
  }

  isColoringDistinctFromGene(coloringMetadataVector, geneContext) {
    if (!coloringMetadataVector || !coloringMetadataVector.values) {
      return false
    }
    const coloringId = String(coloringMetadataVector.id || '')
    const geneMetaId = String(geneContext.geneMetadataId || '')
    const baseGeneId = `gene_${geneContext.geneId}`
    if (coloringId && (coloringId === geneMetaId || coloringId === baseGeneId || coloringId.startsWith(`${baseGeneId}_`))) {
      return false
    }
    if (coloringMetadataVector.values === geneContext.expressionVector.values) {
      return false
    }
    return true
  }

  async downloadGeneExpressionSummary(event) {
    event.preventDefault()
    event.stopPropagation()
    this.controller.closeAllDownloadMenus?.()

    const geneContext = this.resolveGeneExpressionContext(event)
    if (!geneContext) {
      return
    }

    const filteredIndices = this.controller.dataManager.getFilteredCellIndices()
    const filteredSet = filteredIndices ? new Set(filteredIndices) : null
    const hasFilters = filteredSet !== null

    const binning = this.buildContinuousBins(geneContext.expressionVector, filteredSet)
    if (!binning) {
      console.warn('Cannot download gene expression summary: unable to build expression bins')
      return
    }

    if (!window.XLSX) {
      try {
        await this.loadSheetJS()
      } catch (error) {
        console.warn('Could not load Excel library')
        return
      }
    }

    const wb = window.XLSX.utils.book_new()
    const totalCells = geneContext.expressionVector.values.length
    const filteredTotalCells = hasFilters ? filteredSet.size : totalCells
    const { binLabels, totalBinCounts, filteredBinCounts, globalMin, globalMax } = binning

    if (hasFilters) {
      this.addFiltersSheet(wb)
    }

    const geneInfoData = [
      ['Field', 'Value'],
      ['Gene symbol', geneContext.geneSymbol],
      ['Ensembl ID', geneContext.ensemblId || ''],
      ['Stable ID', String(geneContext.geneId)],
      ['Total cells', totalCells]
    ]
    if (hasFilters) {
      geneInfoData.push(['Filtered cells', filteredTotalCells])
    }
    const geneInfoSheet = window.XLSX.utils.aoa_to_sheet(geneInfoData)
    window.XLSX.utils.book_append_sheet(wb, geneInfoSheet, 'Gene Info')

    const binsInfoData = [
      ['Bin Index', 'Bin Label', 'Start', 'End', 'Total Cells', 'Total %', ...(hasFilters ? ['Filtered Cells', 'Filtered %'] : [])]
    ]
    binLabels.forEach((label, i) => {
      const start = globalMin + i * binning.binWidth
      const end = (i === binning.numBins - 1) ? globalMax : (globalMin + (i + 1) * binning.binWidth)
      const totalCount = totalBinCounts[label] || 0
      const totalPercentage = totalCells > 0 ? parseFloat(((totalCount / totalCells) * 100).toFixed(2)) : 0
      const row = [i + 1, label, parseFloat(start.toFixed(6)), parseFloat(end.toFixed(6)), totalCount, totalPercentage]
      if (hasFilters) {
        const filteredCount = filteredBinCounts[label] || 0
        const filteredPercentage = filteredTotalCells > 0
          ? parseFloat(((filteredCount / filteredTotalCells) * 100).toFixed(2))
          : 0
        row.push(filteredCount, filteredPercentage)
      }
      binsInfoData.push(row)
    })
    const binsInfoSheet = window.XLSX.utils.aoa_to_sheet(binsInfoData)
    window.XLSX.utils.book_append_sheet(wb, binsInfoSheet, 'Expression Bins')

    await this.addOverallContinuousSummarySheet(
      wb,
      geneContext.expressionVector,
      filteredSet,
      globalMin,
      globalMax,
      'Overall Stats'
    )

    const coloringMetadataVector = this.controller.currentMetadataVector
    const hasDistinctColoring = this.isColoringDistinctFromGene(coloringMetadataVector, geneContext)

    if (hasDistinctColoring && coloringMetadataVector.data_type === 'DISCRETE') {
      const categoryCounts = {}
      coloringMetadataVector.values.forEach((cat, idx) => {
        if (!filteredSet || filteredSet.has(idx)) {
          categoryCounts[cat] = (categoryCounts[cat] || 0) + 1
        }
      })
      const sortedCategories = Object.keys(categoryCounts).sort((a, b) => {
        return (categoryCounts[b] || 0) - (categoryCounts[a] || 0)
      })

      await this.addContinuousSummarySheet(
        wb,
        coloringMetadataVector,
        geneContext.expressionVector,
        sortedCategories,
        filteredSet,
        'Stats by Category'
      )
      await this.addContinuousDistributionSheet(
        wb,
        coloringMetadataVector,
        geneContext.expressionVector,
        sortedCategories,
        filteredSet
      )
    } else if (hasDistinctColoring && coloringMetadataVector.data_type === 'NUMERIC') {
      const coloringBinning = this.buildContinuousBins(coloringMetadataVector, filteredSet)
      if (coloringBinning) {
        const binnedColoringVector = {
          name: coloringMetadataVector.name || 'Coloring bin',
          values: coloringBinning.binAssignments,
          data_type: 'DISCRETE'
        }
        await this.addContinuousSummarySheet(
          wb,
          binnedColoringVector,
          geneContext.expressionVector,
          coloringBinning.binLabels,
          filteredSet,
          'Stats by Coloring Bin'
        )
        await this.addContinuousDistributionSheet(
          wb,
          binnedColoringVector,
          geneContext.expressionVector,
          coloringBinning.binLabels,
          filteredSet
        )
      }
    }

    const projectKey = this.getProjectKey()
    const geneName = this.sanitizeFilename(geneContext.geneSymbol || geneContext.geneId)
    const coloringSuffix = hasDistinctColoring
      ? `_colored-by_${this.sanitizeFilename(coloringMetadataVector.name)}`
      : ''
    const filterChecksum = hasFilters ? `_${this.calculateFilterChecksum()}` : ''
    const filename = `${projectKey}_gene_${geneName}_expression-summary${coloringSuffix}${filterChecksum}.xlsx`
    window.XLSX.writeFile(wb, filename, { cellStyles: true })
  }

  async downloadGeneExpressionRaw(event) {
    event.preventDefault()
    event.stopPropagation()
    this.controller.closeAllDownloadMenus?.()

    const geneContext = this.resolveGeneExpressionContext(event)
    if (!geneContext) {
      return
    }

    if (typeof CompressionStream === 'undefined') {
      console.warn('Cannot download raw gene expression: CompressionStream is not available in this browser')
      return
    }

    const values = geneContext.expressionVector.values
    const includeCellBarcode = this.isTranscriptomicsProject()
    let cellBarcodes = null

    if (includeCellBarcode) {
      const loomFile = this.controller.currentLoomFile || this.controller.defaultLoomFileValue || null
      cellBarcodes = await this.getCellBarcodesForLoom(loomFile, values.length)
      if (!cellBarcodes) {
        console.warn('Cannot download raw gene expression: /col_attrs/CellID is required for transcriptomics projects')
        return
      }
    }

    const headerParts = ['cell_index']
    if (includeCellBarcode) {
      headerParts.push('cell_barcode')
    }
    headerParts.push('gene_symbol', 'ensembl_id', 'expression')
    const lines = [headerParts.join('\t')]

    for (let i = 0; i < values.length; i++) {
      const value = values[i]
      const expressionValue = (value === null || value === undefined || isNaN(value)) ? '' : String(value)
      const row = [`${i}`]
      if (includeCellBarcode) {
        const barcode = cellBarcodes[i]
        row.push((barcode === null || barcode === undefined) ? '' : String(barcode))
      }
      row.push(geneContext.geneSymbol || '', geneContext.ensemblId || '', expressionValue)
      lines.push(row.join('\t'))
    }

    const gzipBlob = await this.gzipText(lines.join('\n'))
    const projectKey = this.getProjectKey()
    const geneName = this.sanitizeFilename(geneContext.geneSymbol || geneContext.geneId)
    const filename = `${projectKey}_gene_${geneName}_expression_raw.tsv.gz`
    this.triggerBlobDownload(gzipBlob, filename)
  }

  async getCellBarcodesForLoom(loomFile, expectedLength) {
    const cellIdAnnotId = this.resolveCellIdAnnotId(loomFile)
    if (!cellIdAnnotId) {
      console.warn(`Cannot find /col_attrs/CellID annot for loom file: ${loomFile || '(unknown)'}`)
      return null
    }

    let cellIdVector = this.controller.dataManager.getMetadataVectorById(cellIdAnnotId)
    if (!cellIdVector?.values && typeof this.controller.loadSingleMetadataVectorSilently === 'function') {
      await this.controller.loadSingleMetadataVectorSilently(cellIdAnnotId)
      cellIdVector = this.controller.dataManager.getMetadataVectorById(cellIdAnnotId)
    }

    if (!cellIdVector?.values) {
      console.warn(`Cannot load /col_attrs/CellID values for annot ${cellIdAnnotId}`)
      return null
    }

    if (cellIdVector.values.length !== expectedLength) {
      console.warn(
        `CellID length mismatch: expected ${expectedLength}, got ${cellIdVector.values.length}`
      )
      return null
    }

    if (this.controller.dataManager.isDiscreteMetadata(cellIdVector)) {
      const labels = this.controller.dataManager.getCategoryLabels(cellIdVector)
      if (!labels) {
        throw new Error(`Discrete CellID annot ${cellIdAnnotId} is missing compression_info.categories`)
      }
      const barcodes = new Array(cellIdVector.values.length)
      for (let i = 0; i < cellIdVector.values.length; i++) {
        barcodes[i] = labels[cellIdVector.values[i]]
      }
      return barcodes
    }

    return cellIdVector.values
  }

  buildContinuousBins(metadataVector, filteredSet) {
    const values = metadataVector.values
    let globalMin
    let globalMax

    if (
      metadataVector.compression_info &&
      Number.isFinite(metadataVector.compression_info.min_val) &&
      Number.isFinite(metadataVector.compression_info.max_val)
    ) {
      globalMin = metadataVector.compression_info.min_val
      globalMax = metadataVector.compression_info.max_val
    } else {
      const finiteValues = []
      for (let i = 0; i < values.length; i++) {
        const v = values[i]
        if (v !== null && v !== undefined && !isNaN(v)) {
          finiteValues.push(v)
        }
      }
      globalMin = this.controller.dataManager.safeMin(finiteValues)
      globalMax = this.controller.dataManager.safeMax(finiteValues)
    }

    if (!Number.isFinite(globalMin) || !Number.isFinite(globalMax)) {
      return null
    }

    const range = globalMax - globalMin
    const numBins = range === 0 ? 1 : this.numContinuousBins
    const binWidth = range === 0 ? 1 : (range / numBins)

    const binLabels = []
    for (let i = 0; i < numBins; i++) {
      const start = globalMin + i * binWidth
      const end = (i === numBins - 1) ? globalMax : (globalMin + (i + 1) * binWidth)
      if (range === 0) {
        binLabels.push(`${globalMin.toFixed(2)}`)
      } else {
        binLabels.push(`${start.toFixed(2)}-${end.toFixed(2)}`)
      }
    }

    const binAssignments = new Array(values.length)
    const totalBinCounts = {}
    const filteredBinCounts = {}
    binLabels.forEach(label => {
      totalBinCounts[label] = 0
      filteredBinCounts[label] = 0
    })

    for (let i = 0; i < values.length; i++) {
      const value = values[i]
      if (value === null || value === undefined || isNaN(value)) {
        binAssignments[i] = null
        continue
      }

      let binIndex
      if (range === 0) {
        binIndex = 0
      } else {
        binIndex = Math.min(Math.floor((value - globalMin) / binWidth), numBins - 1)
        if (binIndex < 0) binIndex = 0
      }

      const label = binLabels[binIndex]
      binAssignments[i] = label
      totalBinCounts[label]++
      if (!filteredSet || filteredSet.has(i)) {
        filteredBinCounts[label]++
      }
    }

    return {
      binLabels,
      binAssignments,
      totalBinCounts,
      filteredBinCounts,
      globalMin,
      globalMax,
      binWidth,
      numBins
    }
  }

  buildSummaryFilename(displayedMetadataVector, coloringMetadataVector, hasFilters, suffix) {
    const projectKey = this.getProjectKey()
    const displayedMetadataName = this.sanitizeFilename(displayedMetadataVector.name || 'metadata')
    const coloringSuffix = coloringMetadataVector && coloringMetadataVector.values
      ? `_colored-by_${this.sanitizeFilename(coloringMetadataVector.name)}`
      : ''
    const filterChecksum = hasFilters ? `_${this.calculateFilterChecksum()}` : ''
    return `${projectKey}_${displayedMetadataName}_${suffix}${coloringSuffix}${filterChecksum}.xlsx`
  }

  async addOverallContinuousSummarySheet(wb, metadataVector, filteredSet, globalMin, globalMax, sheetName = 'Summary Stats') {
    const values = []
    for (let i = 0; i < metadataVector.values.length; i++) {
      const v = metadataVector.values[i]
      if (v !== null && v !== undefined && !isNaN(v) && (!filteredSet || filteredSet.has(i))) {
        values.push(v)
      }
    }

    const summaryData = [
      ['Metric', 'Value'],
      ['Cell Count', values.length],
      ['Global Min', parseFloat(globalMin.toFixed(6))],
      ['Global Max', parseFloat(globalMax.toFixed(6))],
      ['Number of Bins', this.numContinuousBins]
    ]

    if (values.length > 0) {
      const min = this.controller.dataManager.safeMin(values)
      const max = this.controller.dataManager.safeMax(values)
      const mean = values.reduce((a, b) => a + b, 0) / values.length
      const sortedValues = [...values].sort((a, b) => a - b)
      const median = sortedValues[Math.floor(sortedValues.length / 2)]
      const q1 = sortedValues[Math.floor(sortedValues.length * 0.25)]
      const q3 = sortedValues[Math.floor(sortedValues.length * 0.75)]
      const stdDev = Math.sqrt(values.reduce((sum, val) => sum + Math.pow(val - mean, 2), 0) / values.length)

      summaryData.push(
        ['Min', parseFloat(min.toFixed(4))],
        ['Max', parseFloat(max.toFixed(4))],
        ['Mean', parseFloat(mean.toFixed(4))],
        ['Median', parseFloat(median.toFixed(4))],
        ['Q1', parseFloat(q1.toFixed(4))],
        ['Q3', parseFloat(q3.toFixed(4))],
        ['Std Dev', parseFloat(stdDev.toFixed(4))]
      )
    }

    const ws = window.XLSX.utils.aoa_to_sheet(summaryData)
    window.XLSX.utils.book_append_sheet(wb, ws, sheetName)
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
            const allCategories = this.controller.dataManager.getDiscreteCategoryUniverse(
              parseInt(metadataId, 10),
              metadataVector
            ) || []

            // Only add if not all categories are selected (i.e., it's actually filtering)
            if (selectedCats.size < allCategories.length) {
              const selectedList = [...selectedCats].join(', ')
              const unselectedCategories = allCategories.filter(category => !selectedCats.has(String(category)))
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
    const displayedLabels = this.controller.dataManager.getCategoryLabels(displayedMetadataVector)
    const coloringLabels = this.controller.dataManager.getCategoryLabels(coloringMetadataVector)
    if (!displayedLabels) {
      throw new Error(`Discrete metadata ${displayedMetadataVector.id} is missing compression_info.categories`)
    }
    if (!coloringLabels) {
      throw new Error(`Discrete metadata ${coloringMetadataVector.id} is missing compression_info.categories`)
    }

    // Get coloring categories (from filtered cells only) — key by label
    const coloringCategoryCounts = {}
    const coloringValues = coloringMetadataVector.values
    for (let idx = 0; idx < coloringValues.length; idx++) {
      if (!filteredSet || filteredSet.has(idx)) {
        const cat = String(coloringLabels[coloringValues[idx]])
        coloringCategoryCounts[cat] = (coloringCategoryCounts[cat] || 0) + 1
      }
    }
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
      const displayedCode = this.controller.dataManager.labelToCode(displayedMetadataVector, displayedCategory)
      // Find cells in this category (filtered only)
      const cellsInCategory = []
      if (displayedCode >= 0) {
        for (let i = 0; i < displayedMetadataVector.values.length; i++) {
          if (displayedMetadataVector.values[i] === displayedCode && (!filteredSet || filteredSet.has(i))) {
            cellsInCategory.push(i)
          }
        }
      }

      // Count distribution
      const distribution = {}
      cellsInCategory.forEach(cellIndex => {
        const coloringCat = String(coloringLabels[coloringMetadataVector.values[cellIndex]])
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

  // Add continuous distribution sheets to workbook (counts and percentages separated)
  async addContinuousDistributionSheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet) {
    // Prefer the same range logic as horizontal bar plots when coloring matches current metadata
    let globalMin
    let globalMax
    const effectiveRange = this.controller.getEffectiveColorRange?.()
    if (effectiveRange && coloringMetadataVector.id === this.controller.currentMetadataVector?.id) {
      globalMin = effectiveRange.min
      globalMax = effectiveRange.max
    } else if (
      coloringMetadataVector.compression_info &&
      Number.isFinite(coloringMetadataVector.compression_info.min_val) &&
      Number.isFinite(coloringMetadataVector.compression_info.max_val)
    ) {
      globalMin = coloringMetadataVector.compression_info.min_val
      globalMax = coloringMetadataVector.compression_info.max_val
    } else {
      const filteredValues = coloringMetadataVector.values.filter((v, idx) => {
        return v !== null && v !== undefined && !isNaN(v) && (!filteredSet || filteredSet.has(idx))
      })
      globalMin = this.controller.dataManager.safeMin(filteredValues)
      globalMax = this.controller.dataManager.safeMax(filteredValues)
    }

    if (!Number.isFinite(globalMin) || !Number.isFinite(globalMax)) {
      return
    }
    const numBins = this.numContinuousBins
    const range = globalMax - globalMin
    const binWidth = range === 0 ? 1 : (range / numBins)

    // Create bin ranges header
    const binRanges = []
    for (let i = 0; i < numBins; i++) {
      if (range === 0) {
        binRanges.push(`${globalMin.toFixed(2)}`)
      } else {
        const start = globalMin + i * binWidth
        const end = (i === numBins - 1) ? globalMax : (globalMin + (i + 1) * binWidth)
        binRanges.push(`${start.toFixed(2)}-${end.toFixed(2)}`)
      }
    }

    const displayedLabel = displayedMetadataVector.name || 'Category'
    const coloringLabel = coloringMetadataVector.name || 'Value'
    const columnHeader = `${displayedLabel} \\ ${coloringLabel}`
    const distributionCountsData = [[columnHeader, ...binRanges.map(r => `${r} (# cells)`)]]
    const distributionPercentagesData = [[columnHeader, ...binRanges.map(r => `${r} (% cells)`)]]

    sortedCategories.forEach(displayedCategory => {
      // Find cells in this category (filtered only)
      const displayedCode = this.controller.dataManager.labelToCode(displayedMetadataVector, displayedCategory)
      const cellsInCategory = []
      if (displayedCode >= 0) {
        for (let i = 0; i < displayedMetadataVector.values.length; i++) {
          if (displayedMetadataVector.values[i] === displayedCode && (!filteredSet || filteredSet.has(i))) {
            cellsInCategory.push(i)
          }
        }
      }

      // Get values and create bins
      const values = cellsInCategory.map(idx => coloringMetadataVector.values[idx])
      const validValues = values.filter(v => v !== null && v !== undefined && !isNaN(v))
      const bins = Array(numBins).fill(0)

      validValues.forEach(value => {
        let binIndex
        if (range === 0) {
          binIndex = 0
        } else {
          binIndex = Math.min(Math.floor((value - globalMin) / binWidth), numBins - 1)
          if (binIndex < 0) binIndex = 0
        }
        bins[binIndex]++
      })

      const countsRow = [displayedCategory]
      const percentagesRow = [displayedCategory]
      bins.forEach(count => {
        countsRow.push(count)
        const percentage = validValues.length > 0 ? parseFloat(((count / validValues.length) * 100).toFixed(2)) : 0
        percentagesRow.push(percentage)
      })

      distributionCountsData.push(countsRow)
      distributionPercentagesData.push(percentagesRow)
    })

    const countsSheet = window.XLSX.utils.aoa_to_sheet(distributionCountsData)
    window.XLSX.utils.book_append_sheet(wb, countsSheet, 'Distribution (# cells)')

    const percentagesSheet = window.XLSX.utils.aoa_to_sheet(distributionPercentagesData)
    window.XLSX.utils.book_append_sheet(wb, percentagesSheet, 'Distribution (% cells)')
  }

  // Add continuous summary statistics sheet to workbook
  async addContinuousSummarySheet(wb, displayedMetadataVector, coloringMetadataVector, sortedCategories, filteredSet, sheetName = 'Summary Stats') {
    const summaryData = [['Category', 'Cell Count', 'Min', 'Max', 'Mean', 'Median', 'Q1', 'Q3', 'Std Dev']]

    sortedCategories.forEach(displayedCategory => {
      // Find cells in this category (filtered only)
      const displayedCode = this.controller.dataManager.labelToCode(displayedMetadataVector, displayedCategory)
      const cellsInCategory = []
      if (displayedCode >= 0) {
        for (let i = 0; i < displayedMetadataVector.values.length; i++) {
          if (displayedMetadataVector.values[i] === displayedCode && (!filteredSet || filteredSet.has(i))) {
            cellsInCategory.push(i)
          }
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
    window.XLSX.utils.book_append_sheet(wb, ws, sheetName)
  }

  async gzipText(text) {
    const stream = new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'))
    return new Response(stream).blob()
  }

  triggerBlobDownload(blob, filename) {
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    link.style.visibility = 'hidden'
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    URL.revokeObjectURL(url)
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
            const allCategories = this.controller.dataManager.getDiscreteCategoryUniverse(
              parseInt(metadataId, 10),
              metadataVector
            ) || []
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
