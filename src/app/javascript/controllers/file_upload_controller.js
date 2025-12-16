import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="file-upload"
export default class extends Controller {
  static targets = [
    "fileInput",
    "dropzone",
    "progress",
    "filename",
    "percentage",
    "progressBar",
    "status",
    "inputFilename",
    "submitButton",
    "preparsingPanel",
    "preparsingStatus",
    "preparsingSpinner",
    "preparsingResult",
    "urlInput",
    "downloadUrlButton",
    "downloadForm",
    "fileUploadContainer",
    "uploadInfoFrame",
    "uploadInfoText",
    "parsingParamsContainer",
    "delimiterSelect",
    "geneNameColSelect",
    "hasHeaderCheckbox",
    "resetButton",
    "fileFormatsData",
    "projectName"
  ]

  static values = {
    chunkSize: { type: Number, default: 5 * 1024 * 1024 }, // 5MB
    isAdmin: { type: Boolean, default: false }
  }

  connect() {
    this.currentUpload = null
    this.isUploadComplete = false
    this.fuId = null
    this.originalFilename = null  // Store original uploaded filename
    this.preparsingSubscription = null
    this.preparsingStatusPollInterval = null  // For polling preparsing status
    this.isPreparsingComplete = false
    this.hasMatrixData = false  // Track if we have actual matrix/dataset data
    this.selectedDatasetIndex = null
    this.selectedDatasetName = null
    this.selectedFileIndex = null
    this.selectedFileName = null
    this.archiveFilesData = null  // Store original archive file list data
    this.cameFromArchive = false  // Track if current result came from archive selection
    this.parsingParams = {
      delimiter: '',  // Default to tab (empty string)
      gene_name_col: 'first',
      has_header: true
    }
    this.currentDetectedFormat = null  // Track current file format
    this.projectNameTouched = false
    this.projectNameInputHandler = null
    this._fileFormatsMap = this.loadFileFormats()  // This will also build the extension map
    this.resetPreparsingState()
    this.showUploadInputs()
    this.updateResetButtonState()

    this.form = this.element.closest('form')
    // Fallback: try to find form by ID or by the submit button's form property
    if (!this.form && this.hasSubmitButtonTarget) {
      this.form = this.submitButtonTarget.form
    }
    // Another fallback: find form by action attribute
    if (!this.form) {
      const forms = document.querySelectorAll('form[action*="/projects"]')
      if (forms.length > 0) {
        this.form = forms[0]
      }
    }
    this.projectNameInputElement = this.hasProjectNameTarget
      ? this.projectNameTarget
      : (this.form?.querySelector('[name="project[name]"]') || null)

    if (this.projectNameInputElement) {
      this.projectNameInputHandler = () => {
        this.projectNameTouched = true
      }
      this.projectNameInputElement.addEventListener('input', this.projectNameInputHandler)
    }

    // Ensure spinner animation CSS is available
    this.ensureSpinnerAnimation()

    // Set up global drag/drop prevention immediately
    this.setupGlobalDragDropPrevention()

    // Set up dropzone-specific handlers
    this.setupDropzoneHandlers()
    
    // Set up file input handler
    if (this.hasFileInputTarget) {
      this.fileInputTarget.addEventListener('change', this.handleFileSelect.bind(this))
    }

    // Set up form submission handler
    if (this.form) {
      this.form.addEventListener('submit', this.handleFormSubmit.bind(this))
    } else {
      console.error('[FileUpload] Form not found! Cannot attach submit handler.')
    }

    // Initially disable submit button
    this.checkSubmitButton()
  }

  disconnect() {
    // Clean up event listeners
    this.removeGlobalDragDropPrevention()
    
    if (this.hasFileInputTarget) {
      this.fileInputTarget.removeEventListener('change', this.handleFileSelect)
    }
    
    if (this.form) {
      this.form.removeEventListener('submit', this.handleFormSubmit)
    }
    
    this.teardownPreparsingSubscription()
    if (this.projectNameInputHandler && this.projectNameInputElement) {
      this.projectNameInputElement.removeEventListener('input', this.projectNameInputHandler)
      this.projectNameInputHandler = null
    }
  }

  setupGlobalDragDropPrevention() {
    // Helper to check if this is a file drag/drop
    this.isFileDragDrop = (e) => {
      if (!e.dataTransfer) return false
      
      return e.dataTransfer.types && (
        e.dataTransfer.types.includes('Files') ||
        Array.from(e.dataTransfer.types).some(type => 
          type === 'application/x-moz-file' || 
          type.startsWith('application/')
        )
      ) || (e.dataTransfer.files && e.dataTransfer.files.length > 0)
    }

    // Helper to check if the event target is within the dropzone
    this.isDropzoneTarget = (e) => {
      if (!this.hasDropzoneTarget) return false
      const dropzone = this.dropzoneTarget
      const container = this.element.querySelector('#file-upload-container')
      const target = e.target
      return (dropzone && dropzone.contains(target)) || (container && container.contains(target))
    }

    // Prevent dragenter/dragover events globally (but allow on dropzone)
    this.globalDragHandler = (e) => {
      if (this.isFileDragDrop(e) && !this.isDropzoneTarget(e)) {
        e.preventDefault()
        e.stopPropagation()
        return false
      }
    }

    // Handle drop events globally - prevent default only if NOT on dropzone
    this.globalDropHandler = (e) => {
      if (this.isFileDragDrop(e) && !this.isDropzoneTarget(e)) {
        e.preventDefault()
        return false
      }
    }

    // Set up listeners with capture phase
    ['dragenter', 'dragover'].forEach(eventName => {
      window.addEventListener(eventName, this.globalDragHandler, true)
      document.addEventListener(eventName, this.globalDragHandler, true)
    })

    window.addEventListener('drop', this.globalDropHandler, true)
    document.addEventListener('drop', this.globalDropHandler, true)
    window.addEventListener('dragleave', this.globalDropHandler, true)
    document.addEventListener('dragleave', this.globalDropHandler, true)
  }

  removeGlobalDragDropPrevention() {
    ['dragenter', 'dragover'].forEach(eventName => {
      window.removeEventListener(eventName, this.globalDragHandler, true)
      document.removeEventListener(eventName, this.globalDragHandler, true)
    })

    window.removeEventListener('drop', this.globalDropHandler, true)
    document.removeEventListener('drop', this.globalDropHandler, true)
    window.removeEventListener('dragleave', this.globalDropHandler, true)
    document.removeEventListener('dragleave', this.globalDropHandler, true)
  }

  setupDropzoneHandlers() {
    if (!this.hasDropzoneTarget) return

    const dropzone = this.dropzoneTarget

    // Handle dragover - CRITICAL: Must preventDefault for drop to work
    dropzone.addEventListener('dragover', (e) => {
      e.preventDefault()
      e.stopPropagation()
      e.dataTransfer.dropEffect = 'copy'
      this.highlight()
      return false
    }, false)

    dropzone.addEventListener('dragenter', (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.highlight()
      return false
    }, false)

    dropzone.addEventListener('dragleave', (e) => {
      if (!dropzone.contains(e.relatedTarget)) {
        this.unhighlight()
      }
    }, false)

    dropzone.addEventListener('drop', (e) => {
      e.preventDefault()
      e.stopPropagation()
      this.unhighlight()
      
      const files = e.dataTransfer.files
      if (files && files.length > 0) {
        this.handleFiles(files)
      }
      
      return false
    }, false)

    // Also handle on container if it exists
    const uploadContainer = this.element.querySelector('#file-upload-container')
    if (uploadContainer) {
      uploadContainer.addEventListener('drop', (e) => {
        e.preventDefault()
        e.stopPropagation()
        
        if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
          this.handleFiles(e.dataTransfer.files)
        }
        
        return false
      }, false)
    }
  }

  highlight() {
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.add('border-blue-500')
      this.dropzoneTarget.classList.add('bg-blue-50', 'dark:bg-blue-900')
    }
  }

  unhighlight() {
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.remove('border-blue-500')
      this.dropzoneTarget.classList.remove('bg-blue-50', 'dark:bg-blue-900')
    }
  }

  handleFileSelect(e) {
    this.handleFiles(e.target.files)
  }

  handleFiles(files) {
    if (!files || files.length === 0) return
    
    const file = files[0]
    this.isUploadComplete = false
    this.isPreparsingComplete = false
    this.checkSubmitButton()
    this.startUpload(file)
  }

  async startUpload(file) {
    if (this.currentUpload) {
      if (!confirm('An upload is in progress. Do you want to cancel it and start a new one?')) {
        return
      }
      if (this.currentUpload.abort) {
        this.currentUpload.abort()
      }
    }
    
    // Store original filename without extension
    this.originalFilename = file.name
    const lastDotIndex = this.originalFilename.lastIndexOf('.')
    if (lastDotIndex > 0) {
      this.originalFilename = this.originalFilename.substring(0, lastDotIndex)
    }
    
    this.fuId = null
    this.currentUpload = { file, aborted: false }
    this.updateResetButtonState()
    this.isPreparsingComplete = false
    this.hasMatrixData = false
    this.archiveFilesData = null
    this.cameFromArchive = false
    this.teardownPreparsingSubscription()
    this.resetPreparsingState()
    this.checkSubmitButton()
    
    if (this.hasFilenameTarget) {
      this.filenameTarget.textContent = file.name
    }
    if (this.hasProgressTarget) {
      this.progressTarget.classList.remove('hidden')
    }
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.add('hidden')
    }
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = 'Checking for existing upload...'
    }
    
    try {
      // Check if we can resume an existing upload
      const resumeInfo = await this.checkUploadStatus(file.name)
      if (resumeInfo && resumeInfo.exists && resumeInfo.resumable) {
        this.fuId = resumeInfo.fu_id
        const resumeSize = resumeInfo.size
        const totalSize = resumeInfo.total_size
        
        // Validate total_size to prevent division by zero or invalid percentages
        if (totalSize > 0 && resumeSize >= 0 && resumeSize <= totalSize) {
          const resumePercent = ((resumeSize / totalSize) * 100).toFixed(1)
          
          if (confirm(`Found an incomplete upload (${resumePercent}% complete). Would you like to resume from where you left off?`)) {
            this.updateProgress(resumeSize, totalSize)
            if (this.hasStatusTarget) {
              this.statusTarget.textContent = `Resuming upload from ${this.formatBytes(resumeSize)}...`
            }
            this.subscribeToPreparsing(this.fuId)
          } else {
            this.fuId = null
          }
        } else {
          // Invalid upload state - don't offer resume option
          console.warn(`Invalid upload state: size=${resumeSize}, total_size=${totalSize}. Starting fresh upload.`)
          this.fuId = null
        }
      }
      
      await this.uploadFileInChunks(file)
      
      // Check if upload was aborted (only if currentUpload exists and has aborted property)
      const wasAborted = this.currentUpload && this.currentUpload.aborted
      if (!wasAborted) {
        if (this.hasInputFilenameTarget) {
          this.inputFilenameTarget.value = file.name
        }
        if (this.hasStatusTarget) {
          this.statusTarget.textContent = 'Upload complete!'
          this.statusTarget.classList.remove('text-gray-600')
          this.statusTarget.classList.add('text-green-600')
        }
        this.isUploadComplete = true
        this.updateResetButtonState()
        this.displayUploadSuccess('uploaded', file.name, file.size)
        
        // Ensure fuId is set - if not, try to get it from upload status check
        if (!this.fuId) {
          console.warn('[FileUpload] fuId not set after upload, checking upload status...')
          const uploadStatus = await this.checkUploadStatus(file.name)
          if (uploadStatus && uploadStatus.fu_id) {
            this.fuId = uploadStatus.fu_id
            console.log('[FileUpload] Retrieved fuId from upload status:', this.fuId)
          }
        }
        
        // Ensure websocket subscription is active for preparsing updates
        if (this.fuId) {
          // Always re-subscribe after upload completes to ensure fresh connection
          this.teardownPreparsingSubscription()
          this.subscribeToPreparsing(this.fuId)
        } else {
          console.error('[FileUpload] Cannot subscribe to preparsing: fuId is not set')
        }
        
        this.showPreparsingPanel()
        this.setPreparsingStatus('Upload complete. Preparsing will start automatically.', 'info', true)
        this.checkSubmitButton()
      }
    } catch (error) {
      const wasAborted = this.currentUpload && this.currentUpload.aborted
      if (!wasAborted && this.hasStatusTarget) {
        this.statusTarget.textContent = 'Upload failed: ' + error.message
        this.statusTarget.classList.remove('text-gray-600')
        this.statusTarget.classList.add('text-red-600')
      }
    }
  }

  async uploadFileInChunks(file) {
    const chunkSize = this.chunkSizeValue
    const totalChunks = Math.ceil(file.size / chunkSize)
    let uploadedSize = 0
    
    // If resuming, calculate which chunk to start from
    let startChunkIndex = 0
    if (this.fuId) {
      const resumeInfo = await this.checkUploadStatus(file.name)
      if (resumeInfo && resumeInfo.exists) {
        uploadedSize = resumeInfo.size
        startChunkIndex = Math.floor(uploadedSize / chunkSize)
        if (startChunkIndex >= totalChunks) {
          // Upload is actually complete
          this.isUploadComplete = true
          if (this.hasInputFilenameTarget) {
            this.inputFilenameTarget.value = file.name
          }
          if (this.hasStatusTarget) {
            this.statusTarget.textContent = 'Upload already complete!'
            this.statusTarget.classList.remove('text-gray-600')
            this.statusTarget.classList.add('text-green-600')
          }
          this.checkSubmitButton()
          return
        }
        this.updateProgress(uploadedSize, file.size)
      }
    }
    
    // Upload chunks sequentially
    for (let chunkIndex = startChunkIndex; chunkIndex < totalChunks; chunkIndex++) {
      if (this.currentUpload && this.currentUpload.aborted) {
        throw new Error('Upload cancelled')
      }
      
      const start = chunkIndex * chunkSize
      const end = Math.min(start + chunkSize, file.size)
      const chunk = file.slice(start, end)
      
      const result = await this.uploadChunk(chunk, chunkIndex, totalChunks, file.size)
      
      if (result.fu_id) {
        const fuChanged = this.fuId !== result.fu_id
        this.fuId = result.fu_id
        if (fuChanged) {
          this.subscribeToPreparsing(this.fuId)
        }
      }
      
      uploadedSize = result.uploaded_size || end
      this.updateProgress(uploadedSize, file.size)
    }
  }

  async checkUploadStatus(filename) {
    try {
      const params = new URLSearchParams({ filename })
      if (this.fuId) {
        params.append('fu_id', this.fuId)
      }
      
      const csrfToken = document.querySelector('[name="csrf-token"]')?.content
      const response = await fetch(`/fus/upload_status?${params.toString()}`, {
        method: 'GET',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Accept': 'application/json'
        }
      })
      
      if (response.ok) {
        return await response.json()
      }
      return null
    } catch (error) {
      console.log('Could not check upload status:', error)
      return null
    }
  }

  async uploadChunk(chunk, chunkIndex, totalChunks, fileSize) {
    const formData = new FormData()
    formData.append('chunk', chunk)
    formData.append('chunk_index', chunkIndex)
    formData.append('total_chunks', totalChunks)
    formData.append('file_size', fileSize)
    formData.append('filename', this.currentUpload.file.name)
    
    if (this.fuId) {
      formData.append('fu_id', this.fuId)
    }
    
    const organismField = this.form?.querySelector('[name="project[organism_id]"]')
    if (organismField && organismField.value) {
      formData.append('organism_id', organismField.value)
    }
    
    const versionField = this.form?.querySelector('[name="project[version_id]"]')
    if (versionField && versionField.value) {
      formData.append('version_id', versionField.value)
    }
    
    const csrfToken = document.querySelector('[name="csrf-token"]')?.content
    const response = await fetch('/fus/upload_chunk', {
      method: 'POST',
      headers: {
        'X-CSRF-Token': csrfToken
      },
      body: formData
    })
    
    if (!response.ok) {
      const error = await response.json().catch(() => ({ error: 'Upload failed' }))
      throw new Error(error.error || 'Upload failed')
    }
    
    return await response.json()
  }

  updateProgress(uploaded, total) {
    // Validate inputs to prevent division by zero or invalid percentages
    if (!total || total <= 0 || uploaded < 0) {
      const percentage = 0
      if (this.hasPercentageTarget) {
        this.percentageTarget.textContent = '0%'
      }
      if (this.hasProgressBarTarget) {
        this.progressBarTarget.style.width = '0%'
      }
      if (this.hasStatusTarget) {
        this.statusTarget.textContent = `Uploading... ${this.formatBytes(uploaded)} / ${this.formatBytes(total)}`
      }
      return
    }
    
    // Clamp percentage to valid range (0-100)
    const percentage = Math.min(100, Math.max(0, Math.round((uploaded / total) * 100)))
    
    if (this.hasPercentageTarget) {
      this.percentageTarget.textContent = percentage + '%'
    }
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = percentage + '%'
    }
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = `Uploading... ${this.formatBytes(uploaded)} / ${this.formatBytes(total)}`
    }
  }

  formatBytes(bytes) {
    if (bytes === 0) return '0 Bytes'
    const k = 1024
    const sizes = ['Bytes', 'KB', 'MB', 'GB']
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return Math.round(bytes / Math.pow(k, i) * 100) / 100 + ' ' + sizes[i]
  }

  resetPreparsingState() {
    if (this.hasPreparsingResultTarget) {
      this.preparsingResultTarget.innerHTML = ''
    }
    if (this.hasPreparsingStatusTarget) {
      this.preparsingStatusTarget.textContent = 'Preparsing will start after the upload completes.'
      this.preparsingStatusTarget.classList.remove('text-green-600', 'text-red-600', 'text-yellow-600')
      this.preparsingStatusTarget.classList.add('text-gray-700', 'dark:text-gray-300')
    }
    if (this.hasPreparsingSpinnerTarget) {
      this.preparsingSpinnerTarget.classList.add('hidden')
    }
    if (this.hasPreparsingPanelTarget) {
      this.preparsingPanelTarget.classList.add('hidden')
    }
    this.selectedDatasetIndex = null
    this.selectedDatasetName = null
    this.selectedFileIndex = null
    this.selectedFileName = null
    this.hasMatrixData = false
    this.archiveFilesData = null
    this.cameFromArchive = false
  }

  ensureSpinnerAnimation() {
    // Add CSS for spinner animation if not already added
    if (!document.getElementById('file-upload-spinner-animation-css')) {
      const style = document.createElement('style')
      style.id = 'file-upload-spinner-animation-css'
      style.textContent = `
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `
      document.head.appendChild(style)
    }
  }

  showPreparsingPanel() {
    if (this.hasPreparsingPanelTarget) {
      this.preparsingPanelTarget.classList.remove('hidden')
    }
  }

  setPreparsingStatus(message, variant = 'info', showSpinner = false) {
    if (!this.hasPreparsingStatusTarget) return

    const statusEl = this.preparsingStatusTarget
    const variants = {
      info: ['text-gray-700', 'dark:text-gray-300'],
      success: ['text-green-600'],
      error: ['text-red-600'],
      warning: ['text-yellow-600']
    }

    statusEl.textContent = message
    statusEl.classList.remove('text-gray-700', 'dark:text-gray-300', 'text-green-600', 'text-red-600', 'text-yellow-600')
    statusEl.classList.add(...(variants[variant] || variants.info))

    if (this.hasPreparsingSpinnerTarget) {
      if (showSpinner) {
        this.preparsingSpinnerTarget.classList.remove('hidden')
      } else {
        this.preparsingSpinnerTarget.classList.add('hidden')
      }
    }
  }

  subscribeToPreparsing(fuId) {
    if (!fuId) {
      console.warn('[FileUpload] Cannot subscribe to preparsing: fuId is not set')
      return
    }

    // Check if consumer is available and has subscriptions
    if (!consumer || !consumer.subscriptions) {
      console.error('[FileUpload] ActionCable consumer is not available. Check websocket connection.')
      this.setPreparsingStatus('Websocket connection error. Please refresh the page.', 'error', false)
      return
    }

    this.teardownPreparsingSubscription()
    this.showPreparsingPanel()
    this.setPreparsingStatus('Waiting for preparsing to start...', 'info', true)
    
    try {
      console.log(`[FileUpload] Creating websocket subscription for fu_id: ${fuId}`)
      this.preparsingSubscription = consumer.subscriptions.create(
        { channel: "FuChannel", fu_id: fuId },
        {
          connected: () => {
            console.log(`[FileUpload] Connected to FuChannel for fu_id: ${fuId}`)
            // Check if preparsing is already complete (race condition fix)
            this.checkPreparsingStatus(fuId)
          },
          disconnected: () => {
            console.warn(`[FileUpload] Disconnected from FuChannel for fu_id: ${fuId}`)
            // Try to reconnect after a delay
            setTimeout(() => {
              if (this.fuId === fuId && !this.preparsingSubscription) {
                console.log(`[FileUpload] Attempting to reconnect to FuChannel for fu_id: ${fuId}`)
                this.subscribeToPreparsing(fuId)
              }
            }, 2000)
          },
          rejected: () => {
            console.error(`[FileUpload] Subscription rejected for FuChannel fu_id: ${fuId}`)
            this.setPreparsingStatus('Websocket subscription rejected. Preparsing updates may not work.', 'error', false)
          },
          received: (data) => {
            console.log(`[FileUpload] Received websocket message:`, data)
            this.handlePreparsingUpdate(data)
          }
        }
      )
      
      if (!this.preparsingSubscription) {
        console.error('[FileUpload] Failed to create websocket subscription - subscriptions.create returned null/undefined')
        this.setPreparsingStatus('Failed to establish websocket connection. Preparsing updates may not work.', 'error', false)
      } else {
        console.log(`[FileUpload] Websocket subscription created successfully for fu_id: ${fuId}`)
      }
    } catch (error) {
      console.error('[FileUpload] Error creating websocket subscription:', error)
      console.error('[FileUpload] Error stack:', error.stack)
      this.setPreparsingStatus('Websocket connection error. Preparsing updates may not work.', 'error', false)
    }
  }

  async checkPreparsingStatus(fuId) {
    try {
      const csrfToken = document.querySelector('[name="csrf-token"]')?.content
      const response = await fetch(`/fus/${fuId}/preparsing_status`, {
        method: 'GET',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Accept': 'application/json'
        }
      })

      if (response.ok) {
        const data = await response.json()
        if (data.status === 'preparsed' && data.summary) {
          console.log('[FileUpload] Preparsing already complete, fetching results...')
          // Simulate websocket message format to reuse existing handler
          const websocketData = {
            status: 'completed',
            stage: 'preparsing',
            fu_id: fuId,
            summary: data.summary,
            warnings: data.warnings || [],
            raw_output: data.raw_output,
            prediction_debug: data.prediction_debug
          }
          this.handlePreparsingUpdate(websocketData)
        } else if (data.status === 'preparsing') {
          console.log('[FileUpload] Preparsing in progress, will poll for status...')
          this.setPreparsingStatus('Preparsing in progress. Please wait...', 'info', true)
          // Start polling for status updates (in case websocket misses the message)
          this.startPreparsingStatusPoll(fuId)
        } else if (data.status === 'preparsing_failed') {
          console.log('[FileUpload] Preparsing failed')
          const websocketData = {
            status: 'failed',
            stage: 'preparsing',
            fu_id: fuId,
            error: data.error || 'Preparsing failed'
          }
          this.handlePreparsingUpdate(websocketData)
        }
      }
    } catch (error) {
      console.error('[FileUpload] Error checking preparsing status:', error)
      // Don't show error to user, just wait for websocket update
    }
  }

  teardownPreparsingSubscription() {
    if (this.preparsingSubscription) {
      this.preparsingSubscription.unsubscribe()
      this.preparsingSubscription = null
    }
    // Stop any polling
    if (this.preparsingStatusPollInterval) {
      clearInterval(this.preparsingStatusPollInterval)
      this.preparsingStatusPollInterval = null
    }
  }

  startPreparsingStatusPoll(fuId, maxAttempts = 60) {
    // Stop any existing poll
    if (this.preparsingStatusPollInterval) {
      clearInterval(this.preparsingStatusPollInterval)
    }
    
    let attempts = 0
    this.preparsingStatusPollInterval = setInterval(async () => {
      attempts++
      if (attempts > maxAttempts) {
        clearInterval(this.preparsingStatusPollInterval)
        this.preparsingStatusPollInterval = null
        console.warn('[FileUpload] Stopped polling - max attempts reached')
        return
      }
      
      try {
        const csrfToken = document.querySelector('[name="csrf-token"]')?.content
        const response = await fetch(`/fus/${fuId}/preparsing_status`, {
          method: 'GET',
          headers: {
            'X-CSRF-Token': csrfToken,
            'Accept': 'application/json'
          }
        })

        if (response.ok) {
          const data = await response.json()
          if (data.status === 'preparsed' && data.summary) {
            console.log('[FileUpload] Preparsing complete (from polling), fetching results...')
            clearInterval(this.preparsingStatusPollInterval)
            this.preparsingStatusPollInterval = null
            // Simulate websocket message format to reuse existing handler
            const websocketData = {
              status: 'completed',
              stage: 'preparsing',
              fu_id: fuId,
              summary: data.summary,
              warnings: data.warnings || [],
              raw_output: data.raw_output,
              prediction_debug: data.prediction_debug
            }
            this.handlePreparsingUpdate(websocketData)
          } else if (data.status === 'preparsing_failed') {
            console.log('[FileUpload] Preparsing failed (from polling)')
            clearInterval(this.preparsingStatusPollInterval)
            this.preparsingStatusPollInterval = null
            const websocketData = {
              status: 'failed',
              stage: 'preparsing',
              fu_id: fuId,
              error: data.error || 'Preparsing failed'
            }
            this.handlePreparsingUpdate(websocketData)
          }
          // If still 'preparsing', continue polling
        }
      } catch (error) {
        console.error('[FileUpload] Error polling preparsing status:', error)
      }
    }, 1000) // Poll every second
  }

  handlePreparsingUpdate(data) {
    console.log('[FileUpload] handlePreparsingUpdate called', data)
    console.log('[FileUpload] Data stage:', data?.stage, 'Expected: preparsing')
    console.log('[FileUpload] Data status:', data?.status)
    console.log('[FileUpload] Data fu_id:', data?.fu_id, 'Current fuId:', this.fuId)
    
    if (!data) {
      console.warn('[FileUpload] Ignoring update - no data')
      return
    }
    
    // Check if this update is for the current fuId
    if (data.fu_id && data.fu_id.toString() !== this.fuId?.toString()) {
      console.warn(`[FileUpload] Ignoring update - fu_id mismatch. Update fu_id: ${data.fu_id}, Current fuId: ${this.fuId}`)
      return
    }
    
    if (data.stage !== 'preparsing') {
      console.log('[FileUpload] Ignoring update - wrong stage. Stage:', data.stage, 'Expected: preparsing')
      return
    }

    this.showPreparsingPanel()
    console.log('[FileUpload] Panel should now be visible')

    switch (data.status) {
      case 'started':
        this.hasMatrixData = false  // Reset when new preparsing starts
        this.setPreparsingStatus('Preparsing started. This can take a few minutes.', 'info', true)
        this.checkSubmitButton()
        break
      case 'completed':
        this.isPreparsingComplete = true
        // Check if we have actual dataset/matrix data (not just list_files for ARCHIVE)
        const datasets = Array.isArray(data.summary?.datasets) ? data.summary.datasets : []
        const isArchiveWithFiles = data.summary?.detected_format === 'ARCHIVE' && 
                                   Array.isArray(data.summary?.list_files) && 
                                   data.summary.list_files.length > 0
        // We have matrix data if we have datasets, OR if this is not an archive format requiring file selection
        this.hasMatrixData = datasets.length > 0 || (!isArchiveWithFiles && !data.summary?.displayed_error)
        
        const hasErrors = data.warnings?.length > 0 || data.summary?.displayed_error
        const statusMessage = hasErrors 
          ? 'Preparsing completed with issues. See details below.' 
          : 'Preparsing completed successfully.'
        this.setPreparsingStatus(statusMessage, hasErrors ? 'warning' : 'success')
        // Store raw data for JSON display - prioritize raw_output from Python script
        this.rawPreparsingData = {
          ...data,
          python_raw_output: data.raw_output,  // Raw Python script output
          websocket_message: data,  // Full websocket message
          prediction_debug: data.prediction_debug || data.summary?.prediction_debug || null  // Prediction tool debug data
        }
        this.renderPreparsingResult(data.summary, data.warnings, this.rawPreparsingData)
        this.checkSubmitButton()
        break
      case 'failed':
        this.isPreparsingComplete = false
        this.hasMatrixData = false
        this.setPreparsingStatus(`Preparsing failed${data.error ? `: ${data.error}` : ''}`, 'error')
        // Store raw data even for failures
        this.rawPreparsingData = data
        this.renderPreparsingResult({}, [], data)
        this.checkSubmitButton()
        break
      default:
        break
    }
  }

  renderPreparsingResult(summary = {}, warnings = [], rawData = null) {
    console.log('[FileUpload] renderPreparsingResult called', { summary, warnings, hasTarget: this.hasPreparsingResultTarget })
    console.log('[FileUpload] Summary:', summary)
    if (!this.hasPreparsingResultTarget) {
      console.warn('[FileUpload] preparsingResultTarget not found!')
      return
    }

    this.showPreparsingPanel()
    const datasets = Array.isArray(summary?.datasets) ? summary.datasets : []
    const detectedFormat = summary?.detected_format
    this.currentDetectedFormat = detectedFormat
    console.log('[FileUpload] Datasets found:', datasets.length, datasets)
    let html = ''

    if (Array.isArray(warnings) && warnings.length > 0) {
      const warningText = warnings.map((w) => this.escapeHtml(w)).join('<br/>')
      html += `
        <div class="rounded-md border border-yellow-200 bg-yellow-50 p-3 text-sm text-yellow-900">
          ${warningText}
        </div>
      `
    }

    if (summary?.displayed_error) {
      html += `
        <div class="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-900">
          ${this.escapeHtml(summary.displayed_error)}
        </div>
      `
    }

    // Show parsing parameters for RAW_TEXT format
    if (detectedFormat === 'RAW_TEXT') {
      html += this.buildParsingParametersUI()
    }
    
    // Check for ARCHIVE format with list_files
    const isArchiveFormat = summary?.detected_format === 'ARCHIVE'
    const listFiles = Array.isArray(summary?.list_files) ? summary.list_files : []
    
    // Store archive files data if this is an archive format (for potential back navigation)
    // Only update if we're not currently viewing a result from archive selection
    if (isArchiveFormat && listFiles.length > 0 && !this.cameFromArchive) {
      this.archiveFilesData = {
        listFiles: listFiles,
        detectedFormat: summary?.detected_format
      }
      this.cameFromArchive = false  // Reset when showing archive initially
    }
    
    if (isArchiveFormat && listFiles.length > 0 && !this.cameFromArchive) {
      // ARCHIVE format: show file selection interface
      html += this.buildArchiveFileSelectionUI(listFiles, summary?.detected_format)
    } else if (datasets.length === 0) {
      html += `<p class="text-sm text-gray-600 dark:text-gray-400">No dataset information was returned by the preparsing step.</p>`
    } else if (datasets.length > 1) {
      // Multiple datasets: show selection interface
      html += this.buildDatasetSelectionUI(datasets, summary?.detected_format)
    } else {
      // Single dataset: show directly
      html += datasets.map((dataset, index) => this.buildDatasetCard(dataset, summary?.detected_format, index)).join('')
      
      // Add "Back to archive selection" button if we came from an archive
      if (this.cameFromArchive && this.archiveFilesData && this.archiveFilesData.listFiles && this.archiveFilesData.listFiles.length > 0) {
        html += `
          <div class="mt-4 flex justify-start">
            <button 
              type="button"
              class="px-4 py-2 bg-gray-600 text-white rounded-md hover:bg-gray-700 transition-colors"
              id="back-to-archive-btn"
            >
              Back to Archive File Selection
            </button>
          </div>
        `
      }
    }

    // Add raw JSON output section (admin only)
    let pythonRawOutput = null
    let websocketMessage = null
    if (rawData && this.isAdminValue) {
      pythonRawOutput = rawData.python_raw_output || rawData.raw_output
      websocketMessage = rawData.websocket_message || rawData
      
      // Python script raw output
      if (pythonRawOutput) {
        const pythonJsonString = JSON.stringify(pythonRawOutput, null, 2)
        html += `
          <div class="mt-4 rounded-lg border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-900/50">
            <button 
              type="button"
              class="json-toggle-btn w-full flex items-center justify-between px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
              data-json-type="python"
            >
              <span>Raw Python Script Output (output.json)</span>
              <span class="toggle-icon text-xs">▼</span>
            </button>
            <div class="json-content json-content-python hidden p-4 border-t border-gray-300 dark:border-gray-600">
              <pre class="text-xs overflow-auto max-h-96 bg-white dark:bg-gray-950 p-4 rounded border border-gray-200 dark:border-gray-700"><code>${this.escapeHtml(pythonJsonString)}</code></pre>
              <button 
                type="button"
                class="json-copy-btn mt-2 text-xs text-blue-600 dark:text-blue-400 hover:underline"
                data-json-data='${this.escapeHtml(JSON.stringify(pythonJsonString))}'
              >
                Copy to clipboard
              </button>
            </div>
          </div>
        `
      }
      
      // Websocket message (transformed data)
      const websocketJsonString = JSON.stringify(websocketMessage, null, 2)
      html += `
        <div class="mt-4 rounded-lg border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-900/50">
          <button 
            type="button"
            class="json-toggle-btn w-full flex items-center justify-between px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
            data-json-type="websocket"
          >
            <span>Websocket Message (Transformed Data)</span>
            <span class="toggle-icon text-xs">▼</span>
          </button>
          <div class="json-content json-content-websocket hidden p-4 border-t border-gray-300 dark:border-gray-600">
            <pre class="text-xs overflow-auto max-h-96 bg-white dark:bg-gray-950 p-4 rounded border border-gray-200 dark:border-gray-700"><code>${this.escapeHtml(websocketJsonString)}</code></pre>
            <button 
              type="button"
              class="json-copy-btn mt-2 text-xs text-blue-600 dark:text-blue-400 hover:underline"
              data-json-data='${this.escapeHtml(JSON.stringify(websocketJsonString))}'
            >
              Copy to clipboard
            </button>
          </div>
        </div>
      `
      
      // Prediction tool debug output - always show if available (even if empty)
      const predictionDebug = rawData.prediction_debug || summary?.prediction_debug
      console.log('[FileUpload] Prediction debug data:', predictionDebug)
      // Always show prediction debug section if data exists (even if empty array) or if we have datasets but no prediction data
      if (predictionDebug !== undefined && predictionDebug !== null) {
        const predictionDebugJsonString = JSON.stringify(predictionDebug, null, 2)
        const hasPredictionData = Array.isArray(predictionDebug) && predictionDebug.length > 0
        html += `
          <div class="mt-4 rounded-lg border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-900/50">
            <button 
              type="button"
              class="json-toggle-btn w-full flex items-center justify-between px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
              data-json-type="prediction"
            >
              <span>Prediction Tool Debug Output${hasPredictionData ? '' : ' (no prediction attempts)'}</span>
              <span class="toggle-icon text-xs">▼</span>
            </button>
            <div class="json-content json-content-prediction hidden p-4 border-t border-gray-300 dark:border-gray-600">
              <pre class="text-xs overflow-auto max-h-96 bg-white dark:bg-gray-950 p-4 rounded border border-gray-200 dark:border-gray-700"><code>${this.escapeHtml(predictionDebugJsonString)}</code></pre>
              <button 
                type="button"
                class="json-copy-btn mt-2 text-xs text-blue-600 dark:text-blue-400 hover:underline"
                data-json-data='${this.escapeHtml(JSON.stringify(predictionDebugJsonString))}'
              >
                Copy to clipboard
              </button>
            </div>
          </div>
        `
      }
    }

    this.preparsingResultTarget.innerHTML = html
    
    // Set up event handlers for archive file selection
    if (isArchiveFormat && listFiles.length > 0 && !this.cameFromArchive) {
      this.setupArchiveFileSelectionHandlers(listFiles, summary?.detected_format)
    }
    // Set up event handlers for dataset selection (if multiple datasets)
    else if (datasets.length > 1) {
      this.setupDatasetSelectionHandlers(datasets, summary?.detected_format)
    }
    // Set up back button handler if showing single dataset from archive
    else if (datasets.length === 1 && this.cameFromArchive && this.archiveFilesData) {
      this.setupBackToArchiveHandler()
    }
    
    // Set up parsing parameters handlers if RAW_TEXT format
    if (detectedFormat === 'RAW_TEXT') {
      this.setupParsingParametersHandlers()
    }
    
    // Set up event handlers after HTML is inserted (admin only)
    if (rawData && this.isAdminValue) {
      const toggleBtns = this.preparsingResultTarget.querySelectorAll('.json-toggle-btn')
      toggleBtns.forEach(toggleBtn => {
        const jsonType = toggleBtn.getAttribute('data-json-type')
        let jsonContent = null
        if (jsonType === 'python') {
          jsonContent = this.preparsingResultTarget.querySelector('.json-content-python')
        } else if (jsonType === 'websocket') {
          jsonContent = this.preparsingResultTarget.querySelector('.json-content-websocket')
        } else if (jsonType === 'prediction') {
          jsonContent = this.preparsingResultTarget.querySelector('.json-content-prediction')
        }
        
        if (jsonContent) {
          toggleBtn.addEventListener('click', () => {
            jsonContent.classList.toggle('hidden')
            const icon = toggleBtn.querySelector('.toggle-icon')
            if (icon) {
              icon.textContent = jsonContent.classList.contains('hidden') ? '▼' : '▲'
            }
          })
        }
      })
      
      const copyBtns = this.preparsingResultTarget.querySelectorAll('.json-copy-btn')
      copyBtns.forEach(copyBtn => {
        copyBtn.addEventListener('click', () => {
          const jsonData = copyBtn.getAttribute('data-json-data')
          if (jsonData) {
            // Unescape the JSON string (it's double-encoded)
            let jsonText
            try {
              jsonText = JSON.parse(jsonData)
            } catch (e) {
              jsonText = jsonData
            }
            
            navigator.clipboard.writeText(jsonText).then(() => {
              const originalText = copyBtn.textContent
              copyBtn.textContent = 'Copied!'
              setTimeout(() => {
                copyBtn.textContent = originalText
              }, 2000)
            }).catch(() => {
              alert('Failed to copy to clipboard')
            })
          }
        })
      })
    }
    
    this.updateHiddenDimensions(summary?.primary_dimensions)
  }

  buildArchiveFileSelectionUI(listFiles, detectedFormat) {
    let html = `
      <div class="rounded-lg border border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-900/20 p-4 mb-4">
        <div class="flex items-center gap-3 mb-4">
          ${this.getFileFormatIcon(detectedFormat)}
          <p class="text-sm font-medium text-blue-900 dark:text-blue-200">
            Multiple files found in this archive. Please select one file to process:
          </p>
        </div>
        <div class="mb-4">
          <select 
            id="archive-file-select"
            class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white text-sm"
          >
            <option value="">Select a file from this archive</option>
    `
    
    listFiles.forEach((fileObj, index) => {
      const filename = fileObj?.filename || fileObj || `File ${index + 1}`
      const isSelected = this.selectedFileIndex === index
      
      html += `
            <option value="${index}" ${isSelected ? 'selected' : ''} data-filename="${this.escapeHtml(filename)}">
              ${this.escapeHtml(filename)}
            </option>
      `
    })
    
    html += `
          </select>
        </div>
        <div class="flex justify-end">
          <button 
            type="button"
            class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed transition-colors"
            id="select-archive-file-btn"
            ${this.selectedFileIndex === null ? 'disabled' : ''}
          >
            Process Selected File
          </button>
        </div>
      </div>
    `
    
    return html
  }

  setupArchiveFileSelectionHandlers(listFiles, detectedFormat) {
    // Handle dropdown selection changes
    const fileSelect = this.preparsingResultTarget.querySelector('#archive-file-select')
    const selectButton = this.preparsingResultTarget.querySelector('#select-archive-file-btn')
    
    if (fileSelect) {
      fileSelect.addEventListener('change', (e) => {
        const selectedValue = e.target.value
        
        if (selectedValue === '' || selectedValue === null) {
          // No file selected
          this.selectedFileIndex = null
          this.selectedFileName = null
          if (selectButton) {
            selectButton.disabled = true
          }
        } else {
          const index = parseInt(selectedValue)
          this.selectedFileIndex = index
          
          // Get filename from the file object or the option's data attribute
          const fileObj = listFiles[index]
          const selectedOption = e.target.options[e.target.selectedIndex]
          const filename = fileObj?.filename || fileObj || selectedOption?.getAttribute('data-filename') || null
          this.selectedFileName = filename
          
          // Enable select button
          if (selectButton) {
            selectButton.disabled = false
          }
        }
      })
    }
    
    // Handle "Process Selected File" button click
    if (selectButton) {
      selectButton.addEventListener('click', async () => {
        if (this.selectedFileIndex === null || !this.fuId) return
        
        const fileObj = listFiles[this.selectedFileIndex]
        const filename = fileObj?.filename || fileObj || this.selectedFileName
        
        if (!filename) {
          alert('Error: Could not determine file name. Please try again.')
          return
        }
        
        // Store selected filename without extension for dataset label
        let selectedFilenameWithoutExt = filename
        const lastDotIndex = selectedFilenameWithoutExt.lastIndexOf('.')
        if (lastDotIndex > 0) {
          selectedFilenameWithoutExt = selectedFilenameWithoutExt.substring(0, lastDotIndex)
        }
        this.originalFilename = selectedFilenameWithoutExt
        
        // Re-run preparsing with selected file
        // Mark that we came from archive so we can show back button later
        this.cameFromArchive = true
        await this.rerunPreparsingWithDataset(filename)
      })
    }
  }

  setupBackToArchiveHandler() {
    const backButton = this.preparsingResultTarget.querySelector('#back-to-archive-btn')
    if (backButton && this.archiveFilesData) {
      backButton.addEventListener('click', () => {
        // Reset the cameFromArchive flag and show archive selection again
        this.cameFromArchive = false
        this.hasMatrixData = false
        this.selectedFileIndex = null
        this.selectedFileName = null
        
        // Re-render the archive file selection UI
        const summary = {
          detected_format: this.archiveFilesData.detectedFormat || 'ARCHIVE',
          list_files: this.archiveFilesData.listFiles
        }
        this.renderPreparsingResult(summary, [], this.rawPreparsingData)
        this.checkSubmitButton()
      })
    }
  }

  buildDatasetSelectionUI(datasets, detectedFormat) {
    const archiveFormats = ['ARCHIVE', 'ARCHIVE_COMPRESSED']
    const isArchiveFormat = archiveFormats.includes(detectedFormat)
    const datasetMessage = isArchiveFormat
      ? 'Multiple datasets found in this archive. Please select one to proceed:'
      : 'Multiple datasets found in this file. Please select one to proceed:'

    let html = `
      <div class="rounded-lg border border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-900/20 p-4 mb-4">
        <div class="flex items-center gap-3 mb-2">
          ${this.getFileFormatIcon(detectedFormat)}
          <p class="text-sm font-medium text-blue-900 dark:text-blue-200">
            ${datasetMessage}
          </p>
        </div>
      </div>
      <div class="space-y-3 mb-4">
    `
    
    datasets.forEach((dataset, index) => {
      const label = dataset?.name || `Dataset ${index + 1}`
      const cells = this.formatNumber(dataset?.cell_count)
      const genes = this.formatNumber(dataset?.gene_count)
      const isSelected = this.selectedDatasetIndex === index
      
      html += `
        <div class="dataset-option rounded-lg border-2 p-4 cursor-pointer transition-all ${
          isSelected 
            ? 'border-blue-500 bg-blue-50 dark:bg-blue-900/30' 
            : 'border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800/80 hover:border-blue-300 dark:hover:border-blue-700'
        }" 
        data-dataset-index="${index}"
        data-dataset-name="${this.escapeHtml(dataset?.name || '')}">
          <div class="flex items-start gap-3">
            <input 
              type="radio" 
              name="dataset_selection" 
              value="${index}" 
              ${isSelected ? 'checked' : ''}
              class="mt-1"
              id="dataset-${index}"
            />
            <label for="dataset-${index}" class="flex-1 cursor-pointer">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <p class="text-base font-semibold text-gray-900 dark:text-white">${this.escapeHtml(label)}</p>
                </div>
              </div>
              <dl class="mt-2 grid grid-cols-2 gap-3 text-sm text-gray-600 dark:text-gray-300">
                <div>
                  <dt class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Cells</dt>
                  <dd class="text-sm font-medium text-gray-900 dark:text-white">${cells}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Genes</dt>
                  <dd class="text-sm font-medium text-gray-900 dark:text-white">${genes}</dd>
                </div>
              </dl>
            </label>
          </div>
        </div>
      `
    })
    
    html += `
      </div>
      <div class="flex justify-end">
        <button 
          type="button"
          class="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed transition-colors"
          id="select-dataset-btn"
          ${this.selectedDatasetIndex === null ? 'disabled' : ''}
        >
          Process Selected Dataset
        </button>
      </div>
    `
    
    // Show selected dataset details if one is already selected
    if (this.selectedDatasetIndex !== null && this.selectedDatasetIndex >= 0 && this.selectedDatasetIndex < datasets.length) {
      html += `
        <div class="mt-6 pt-6 border-t border-gray-200 dark:border-gray-700">
          <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-4">Selected Dataset Details</h3>
          ${this.buildDatasetCard(datasets[this.selectedDatasetIndex], detectedFormat, this.selectedDatasetIndex)}
        </div>
      `
    }
    
    return html
  }

  setupDatasetSelectionHandlers(datasets, detectedFormat) {
    // Handle radio button clicks
    const radioButtons = this.preparsingResultTarget.querySelectorAll('input[name="dataset_selection"]')
    const selectButton = this.preparsingResultTarget.querySelector('#select-dataset-btn')
    
    radioButtons.forEach(radio => {
      radio.addEventListener('change', (e) => {
        const index = parseInt(e.target.value)
        const dataset = datasets[index]
        this.selectedDatasetIndex = index
        const datasetDisplayName = this.getDatasetDisplayName(dataset)
        this.selectedDatasetName = datasetDisplayName || dataset?.name || dataset?.group || null
        this.maybeSetProjectNameFromDataset(this.selectedDatasetName)
        
        // Update UI to highlight selected option
        const options = this.preparsingResultTarget.querySelectorAll('.dataset-option')
        options.forEach((option, optIndex) => {
          if (optIndex === index) {
            option.classList.remove('border-gray-200', 'dark:border-gray-700')
            option.classList.add('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
          } else {
            option.classList.remove('border-blue-500', 'bg-blue-50', 'dark:bg-blue-900/30')
            option.classList.add('border-gray-200', 'dark:border-gray-700')
          }
        })
        
        // Enable select button
        if (selectButton) {
          selectButton.disabled = false
        }
      })
    })
    
    // Handle click on dataset option divs (not just radio buttons)
    const options = this.preparsingResultTarget.querySelectorAll('.dataset-option')
    options.forEach(option => {
      option.addEventListener('click', (e) => {
        // Don't trigger if clicking on the radio button itself
        if (e.target.type !== 'radio') {
          const radio = option.querySelector('input[type="radio"]')
          if (radio) {
            radio.checked = true
            radio.dispatchEvent(new Event('change'))
          }
        }
      })
    })
    
    // Handle "Process Selected Dataset" button click
    if (selectButton) {
      selectButton.addEventListener('click', async () => {
        if (this.selectedDatasetIndex === null || !this.fuId) return
        
        const selectedDataset = datasets[this.selectedDatasetIndex]
        const datasetName = selectedDataset?.name
        
        if (!datasetName) {
          alert('Error: Could not determine dataset name. Please try again.')
          return
        }
        
        // Store selected dataset/filename without extension for dataset label
        let selectedNameWithoutExt = datasetName
        const lastDotIndex = selectedNameWithoutExt.lastIndexOf('.')
        if (lastDotIndex > 0) {
          selectedNameWithoutExt = selectedNameWithoutExt.substring(0, lastDotIndex)
        }
        this.originalFilename = selectedNameWithoutExt
        
        // Re-run preparsing with selected dataset
        await this.rerunPreparsingWithDataset(datasetName)
      })
    }
  }

  async rerunPreparsingWithDataset(datasetName) {
    if (!this.fuId || !datasetName) return

    this.maybeSetProjectNameFromDataset(datasetName)
    this.setPreparsingStatus(`Re-running preparsing for: ${this.escapeHtml(datasetName)}...`, 'info', true)
    
    // Disable the select button during processing (could be dataset or archive file button)
    const selectDatasetButton = this.preparsingResultTarget.querySelector('#select-dataset-btn')
    const selectArchiveButton = this.preparsingResultTarget.querySelector('#select-archive-file-btn')
    const selectButton = selectDatasetButton || selectArchiveButton
    const originalButtonText = selectButton ? selectButton.textContent : null
    
    if (selectButton) {
      selectButton.disabled = true
      selectButton.textContent = 'Processing...'
    }
    
    try {
      // Get organism_id and version_id from form
      const organismField = this.form?.querySelector('[name="project[organism_id]"]')
      const versionField = this.form?.querySelector('[name="project[version_id]"]')
      
      const requestBody = {
        sel: datasetName
      }
      
      // Include parsing parameters if available (for text files)
      if (this.parsingParams) {
        if (this.parsingParams.delimiter !== undefined) {
          requestBody.delimiter = this.parsingParams.delimiter
        }
        if (this.parsingParams.gene_name_col !== undefined) {
          requestBody.gene_name_col = this.parsingParams.gene_name_col
        }
        if (this.parsingParams.has_header !== undefined) {
          requestBody.has_header = this.parsingParams.has_header ? '1' : '0'
        }
      }
      
      if (organismField && organismField.value) {
        requestBody.organism_id = organismField.value
      }
      
      if (versionField && versionField.value) {
        requestBody.version_id = versionField.value
      }
      
      const csrfToken = document.querySelector('[name="csrf-token"]')?.content
      const response = await fetch(`/fus/${this.fuId}/rerun_preparsing`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: JSON.stringify(requestBody)
      })
      
      if (!response.ok) {
        const error = await response.json().catch(() => ({ error: 'Failed to re-run preparsing' }))
        throw new Error(error.error || 'Failed to re-run preparsing')
      }
      
      // Always re-subscribe when rerunning preparsing to ensure fresh connection
      if (this.fuId) {
        console.log('[FileUpload] Re-subscribing to preparsing websocket for dataset rerun')
        this.subscribeToPreparsing(this.fuId)
        // Start polling as fallback in case websocket misses the update
        this.startPreparsingStatusPoll(this.fuId)
      }
      
      // The websocket will handle the update when preparsing completes
      this.setPreparsingStatus(`Preparsing for "${this.escapeHtml(datasetName)}" started. Please wait...`, 'info', true)
    } catch (error) {
      console.error('Error re-running preparsing:', error)
      this.setPreparsingStatus(`Error: ${error.message}`, 'error')
      if (selectButton && originalButtonText) {
        selectButton.disabled = false
        selectButton.textContent = originalButtonText
      }
    }
  }

  // Format memory (bytes) to human-readable format (b, Kb, Mb, Gb)
  formatMemory(bytes) {
    if (!bytes && bytes !== 0) return 'n/a'
    
    const g = bytes / 1000000000
    const m = bytes / 1000000
    const k = bytes / 1000
    
    if (g >= 1) {
      const precision = Math.max(0, 3 - Math.floor(g).toString().length)
      return `${g.toFixed(precision)}Gb`
    } else if (m >= 1) {
      const precision = Math.max(0, 3 - Math.floor(m).toString().length)
      return `${m.toFixed(precision)}Mb`
    } else if (k >= 1) {
      const precision = Math.max(0, 3 - Math.floor(k).toString().length)
      return `${k.toFixed(precision)}Kb`
    } else {
      const precision = Math.max(0, 3 - Math.floor(bytes).toString().length)
      return `${bytes.toFixed(precision)}b`
    }
  }

  // Format duration (seconds) to human-readable format (d, h, m, s)
  formatDuration(secs) {
    if (!secs && secs !== 0) return 'n/a'
    if (secs === 0) return '0s'
    
    const mins = Math.floor(secs / 60)
    const hours = Math.floor(mins / 60)
    const days = Math.floor(hours / 24)
    
    const parts = []
    if (days >= 1) {
      parts.push(`${days}d`)
    }
    if (hours >= 1) {
      parts.push(`${hours % 24}h`)
    }
    if (mins >= 1 && days === 0) {
      parts.push(`${mins % 60}m`)
    }
    if (secs >= 0 && hours === 0) {
      parts.push(`${secs % 60}s`)
    }
    
    return parts.length > 0 ? parts.join(' ') : '0s'
  }

  buildDatasetCard(dataset, detectedFormat, index) {
    const datasetName = this.getDatasetDisplayName(dataset)

    // Use original uploaded filename (without extension) if available, otherwise use dataset name
    let label = this.originalFilename || datasetName || `Dataset ${index + 1}`
    
    // Always remove extension from label for display
    // Skip if it's the default "Dataset X" label
    if (label && label !== `Dataset ${index + 1}`) {
      const hasSlash = label.includes('/')
      const hasExtension = label.includes('.')
      // Remove extension if it exists and there's no slash (path separator)
      if (!hasSlash && hasExtension) {
        label = label.replace(/\.[^.]+$/, '')
      }
    }
    const cells = this.formatNumber(dataset?.cell_count)
    const genes = this.formatNumber(dataset?.gene_count)
    const metadataCount = Array.isArray(dataset?.existing_metadata) ? dataset.existing_metadata.length : 0
    const matrixType = dataset?.is_count_matrix ? 'Count matrix' : 'Expression matrix'
    // Format predicted RAM (value is in KB, convert to bytes for formatting)
    const predictedRamValue = dataset?.predicted_ram
    const predictedRam = predictedRamValue ? this.formatMemory(predictedRamValue * 1000) : 'n/a'
    
    // Format predicted duration (value is in seconds)
    const predictedDurationValue = dataset?.predicted_duration
    const predictedDuration = predictedDurationValue ? this.formatDuration(predictedDurationValue) : 'n/a'
    
    // Sample matrix data
    const sampleMatrix = Array.isArray(dataset?.sample_matrix) ? dataset.sample_matrix : []
    const geneNames = Array.isArray(dataset?.genes) ? dataset.genes : []
    const cellNames = Array.isArray(dataset?.cells) ? dataset.cells : []
    const hasSampleMatrix = sampleMatrix.length > 0 && sampleMatrix[0] && Array.isArray(sampleMatrix[0])

    let sampleMatrixHtml = ''
    if (hasSampleMatrix) {
      // Limit displayed rows/cols for performance
      const maxRows = Math.min(sampleMatrix.length, 10)
      const maxCols = sampleMatrix[0] ? Math.min(sampleMatrix[0].length, 10) : 0
      
      let tableHtml = '<table class="w-full text-xs border-collapse border border-gray-300 dark:border-gray-600">'
      
      // Header row with cell names
      if (cellNames.length > 0) {
        tableHtml += '<thead><tr>'
        tableHtml += '<th class="border border-gray-300 dark:border-gray-600 bg-gray-100 dark:bg-gray-700 p-1 text-left font-semibold"></th>' // Empty corner
        for (let col = 0; col < maxCols; col++) {
          const cellName = cellNames[col] || `Cell ${col + 1}`
          tableHtml += `<th class="border border-gray-300 dark:border-gray-600 bg-gray-100 dark:bg-gray-700 p-1 text-left font-semibold">${this.escapeHtml(cellName)}</th>`
        }
        if (sampleMatrix[0] && sampleMatrix[0].length > maxCols) {
          tableHtml += `<th class="border border-gray-300 dark:border-gray-600 bg-gray-100 dark:bg-gray-700 p-1 text-left font-semibold">...</th>`
        }
        tableHtml += '</tr></thead>'
      }
      
      // Data rows
      tableHtml += '<tbody>'
      for (let row = 0; row < maxRows; row++) {
        tableHtml += '<tr>'
        // Gene name column
        if (geneNames.length > row) {
          tableHtml += `<td class="border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-800 p-1 font-semibold text-right">${this.escapeHtml(geneNames[row])}</td>`
        } else {
          tableHtml += `<td class="border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-800 p-1 font-semibold text-right">Gene ${row + 1}</td>`
        }
        // Matrix values
        for (let col = 0; col < maxCols; col++) {
          const value = sampleMatrix[row] && sampleMatrix[row][col] !== undefined ? sampleMatrix[row][col] : ''
          tableHtml += `<td class="border border-gray-300 dark:border-gray-600 p-1 text-right">${this.escapeHtml(String(value))}</td>`
        }
        // Ellipsis if more columns
        if (sampleMatrix[row] && sampleMatrix[row].length > maxCols) {
          tableHtml += '<td class="border border-gray-300 dark:border-gray-600 p-1 text-center">...</td>'
        }
        tableHtml += '</tr>'
      }
      // Ellipsis row if more rows
      if (sampleMatrix.length > maxRows) {
        tableHtml += '<tr>'
        tableHtml += '<td class="border border-gray-300 dark:border-gray-600 p-1 text-center">...</td>'
        for (let col = 0; col < maxCols; col++) {
          tableHtml += '<td class="border border-gray-300 dark:border-gray-600 p-1 text-center">...</td>'
        }
        if (sampleMatrix[0] && sampleMatrix[0].length > maxCols) {
          tableHtml += '<td class="border border-gray-300 dark:border-gray-600 p-1"></td>'
        }
        tableHtml += '</tr>'
      }
      tableHtml += '</tbody></table>'
      
      sampleMatrixHtml = `
        <div class="mt-4">
          <p class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400 mb-2">Sample Matrix (first ${maxRows} genes, first ${maxCols} cells)</p>
          <div class="overflow-x-auto max-w-full">
            ${tableHtml}
          </div>
        </div>
      `
    }

    // Pass the display label (after extension removal) to project name setter
    // so project name matches exactly what's displayed
    this.maybeSetProjectNameFromDataset(label)

    return `
      <div class="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800/80 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <p class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Dataset</p>
            <p class="text-lg font-semibold text-gray-900 dark:text-white">${this.escapeHtml(label)}</p>
          </div>
          ${this.getFileFormatIcon(detectedFormat)}
        </div>
        <dl class="mt-4 grid grid-cols-2 gap-4 text-sm text-gray-600 dark:text-gray-300">
          <div>
            <dt class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Cells (columns)</dt>
            <dd class="text-base font-medium text-gray-900 dark:text-white">${cells}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Genes (rows)</dt>
            <dd class="text-base font-medium text-gray-900 dark:text-white">${genes}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Matrix type</dt>
            <dd class="text-base font-medium text-gray-900 dark:text-white">${this.escapeHtml(matrixType)}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Metadata columns</dt>
            <dd class="text-base font-medium text-gray-900 dark:text-white">${metadataCount}</dd>
          </div>
          ${(predictedRam !== 'n/a' || predictedDuration !== 'n/a') ? `
          <div class="md:col-span-2">
            <dt class="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">Resource prediction for parsing</dt>
            <dd class="text-base font-medium text-gray-900 dark:text-white mt-2 flex flex-wrap gap-2">
              ${predictedRam !== 'n/a' ? `<span class="inline-block px-2 py-1 bg-gray-100 dark:bg-gray-700 rounded text-sm">Maximum RAM: ${this.escapeHtml(predictedRam)}</span>` : ''}
              ${predictedDuration !== 'n/a' ? `<span class="inline-block px-2 py-1 bg-gray-100 dark:bg-gray-700 rounded text-sm">Execution time: ${this.escapeHtml(predictedDuration)}</span>` : ''}
            </dd>
          </div>
          ` : ''}
        </dl>
        ${sampleMatrixHtml}
      </div>
    `
  }

  updateHiddenDimensions(dimensions) {
    if (!dimensions) return
    
    const rowsInput = this.element.querySelector('input[name="nber_rows"]')
    const colsInput = this.element.querySelector('input[name="nber_cols"]')
    if (rowsInput && dimensions.nber_rows) {
      rowsInput.value = dimensions.nber_rows
    }
    if (colsInput && dimensions.nber_cols) {
      colsInput.value = dimensions.nber_cols
    }
  }

  escapeHtml(value) {
    if (value === null || value === undefined) return ''
    return String(value).replace(/[&<>"']/g, (char) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;'
    }[char]))
  }

  formatNumber(value) {
    if (value === null || value === undefined || value === '') return 'n/a'
    const number = Number(value)
    return Number.isFinite(number) ? number.toLocaleString() : this.escapeHtml(value)
  }

  getDatasetDisplayName(dataset) {
    if (!dataset) {
      return this.selectedDatasetName || this.originalFilename || ''
    }

    // Prioritize name property (set from group['group'] in Ruby)
    // Then fall back to other possible properties
    const name = dataset?.name || 
                 dataset?.group || 
                 dataset?.label || 
                 dataset?.display_name ||
                 dataset?.filename ||
                 dataset?.file_name ||
                 this.selectedDatasetName ||
                 this.originalFilename ||
                 ''

    return name
  }

  maybeSetProjectNameFromDataset(datasetName) {
    if (this.projectNameTouched) return

    const inputEl = this.projectNameInputElement ||
      this.projectNameTarget ||
      this.form?.querySelector('[name="project[name]"]')

    if (!inputEl) return

    const trimmed = (datasetName || '').trim()
    if (!trimmed) return

    // Use the dataset name as-is (it should already be the display name without extensions)
    inputEl.value = trimmed
  }

  showUploadInputs() {
    if (this.hasFileUploadContainerTarget) {
      this.fileUploadContainerTarget.classList.remove('hidden')
    }
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.remove('hidden')
    }
    if (this.hasDownloadFormTarget) {
      this.downloadFormTarget.classList.remove('hidden')
    }
    if (this.hasUploadInfoFrameTarget) {
      this.uploadInfoFrameTarget.classList.add('hidden')
    }
    if (this.hasUploadInfoTextTarget) {
      this.uploadInfoTextTarget.textContent = ''
    }
  }

  hideUploadInputs() {
    if (this.hasFileUploadContainerTarget) {
      this.fileUploadContainerTarget.classList.add('hidden')
    }
    if (this.hasDownloadFormTarget) {
      this.downloadFormTarget.classList.add('hidden')
    }
  }

  displayUploadSuccess(action, filename, sizeInBytes) {
    this.hideUploadInputs()

    if (this.hasUploadInfoTextTarget) {
      const verb = action === 'downloaded' ? 'downloaded' : 'uploaded'
      const safeName = filename || 'file'
      let message = `Successfully ${verb} ${safeName}`
      const sizeNumber = Number(sizeInBytes)
      if (!Number.isNaN(sizeNumber) && sizeNumber > 0) {
        message += ` (${this.formatBytes(sizeNumber)})`
      }
      this.uploadInfoTextTarget.textContent = message
    }

    if (this.hasUploadInfoFrameTarget) {
      this.uploadInfoFrameTarget.classList.remove('hidden')
    }
  }

  loadFileFormats() {
    if (!this.hasFileFormatsDataTarget) return {}
    const rawValue = (this.fileFormatsDataTarget.textContent || '').trim()
    if (!rawValue) return {}

    try {
      const parsed = JSON.parse(rawValue)
      const formats = parsed && typeof parsed === 'object' ? parsed : {}
      // Rebuild extension map when formats are loaded
      this._extensionToFormatMap = this.buildExtensionToFormatMap()
      return formats
    } catch (error) {
      console.error('[FileUpload] Failed to parse file format metadata:', error)
      return {}
    }
  }

  get fileFormatsMap() {
    return this._fileFormatsMap || {}
  }

  buildExtensionToFormatMap() {
    const extensionMap = {}
    const multiExtensionPatterns = [] // Store patterns with dots for multi-extension matching
    const compressionExtensions = [] // Store compression-only extensions (from COMPRESSED format)
    const formatsMap = this.fileFormatsMap

    // Build reverse lookup: extension -> format key
    Object.keys(formatsMap).forEach(formatKey => {
      const format = formatsMap[formatKey]
      if (format && Array.isArray(format.extensions)) {
        format.extensions.forEach(ext => {
          // Normalize extension (remove leading dot if present, convert to lowercase)
          const normalizedExt = ext.replace(/^\./, '').toLowerCase().trim()
          if (normalizedExt) {
            // Check if this is a multi-extension pattern (contains dots)
            if (normalizedExt.includes('.')) {
              // Store as a pattern to check against full filename
              multiExtensionPatterns.push({
                pattern: new RegExp(`\\.${normalizedExt.replace(/\./g, '\\.')}$`),
                format: formatKey
              })
            } else {
              // Single extension - store in map
              if (!extensionMap[normalizedExt]) {
                extensionMap[normalizedExt] = formatKey
              }
              
              // If this is the COMPRESSED format, also store these as compression extensions
              // These are extensions that can be stripped to get to the base file format
              if (formatKey === 'COMPRESSED') {
                compressionExtensions.push(normalizedExt)
              }
            }
          }
        })
      }
    })

    return { single: extensionMap, multi: multiExtensionPatterns, compression: compressionExtensions }
  }

  getFileFormatIcon(formatName) {
    const formatKey = (formatName || 'UNKNOWN').toString().toUpperCase()
    const config = this.fileFormatsMap[formatKey] || this.fileFormatsMap['UNKNOWN'] || {}
    const color = config.color || '#6B7280'
    const label = config.label || (formatKey === 'UNKNOWN' ? '?' : formatKey)

    return `<i class="far fa-file fa-3x"><div style="position:relative;top:-26px;left:6px;width:38px;font-size:10px;font-weight:bold;text-align:center;font-family:Arial, Helvetica, sans-serif;background-color:${this.escapeHtml(color)};color:white;padding:3px;border:2px solid white">${this.escapeHtml(label)}</div></i>`
  }

  determineFormatKeyFromFilename(filename) {
    if (!filename) return 'UNKNOWN'
    const lowerName = filename.toLowerCase()

    const extensionData = this._extensionToFormatMap || { single: {}, multi: [] }

    // Check for multi-extension patterns first (e.g., .tar.gz, .zip, .tgz)
    // These are stored with their full pattern including dots
    for (const { pattern, format } of extensionData.multi || []) {
      if (pattern.test(lowerName)) {
        return format
      }
    }

    // Remove compression extensions to get the base extension
    // This handles cases like file.txt.gz -> file.txt
    // Note: We've already checked multi-extension patterns above, so we know none matched
    let stripped = lowerName
    const compressionExts = (extensionData.compression || []).map(ext => `.${ext}`)
    
    compressionExts.forEach(ext => {
      if (stripped.endsWith(ext)) {
        stripped = stripped.slice(0, -ext.length)
      }
    })

    // Extract the last extension (after the last dot)
    const ext = stripped.split('.').pop()?.toLowerCase()

    if (!ext) return 'UNKNOWN'

    // Look up single extension in the map built from FileFormat data
    if (extensionData.single && extensionData.single[ext]) {
      return extensionData.single[ext]
    }

    return 'UNKNOWN'
  }

  checkSubmitButton() {
    if (!this.hasSubmitButtonTarget) return

    // Check if all required conditions are met:
    // 1. File uploaded
    // 2. Preparsing completed AND has actual matrix/dataset data
    const hasValidPreparsing = this.isPreparsingComplete && this.hasMatrixData

    // 3. Organism is selected
    const organismField = this.form?.querySelector('[name="project[organism_id]"]')
    const hasOrganism = organismField && organismField.value && organismField.value !== ''

    // 4. Release (version_id) is selected
    const versionField = this.form?.querySelector('[name="project[version_id]"]')
    const hasVersion = versionField && versionField.value && versionField.value !== ''

    // 5. Project type is selected
    const projectTypeField = this.form?.querySelector('[name="project[project_type_id]"]')
    const hasProjectType = projectTypeField && projectTypeField.value && projectTypeField.value !== ''

    // Enable button only if all conditions are met
    const shouldEnable = this.isUploadComplete && hasValidPreparsing && hasOrganism && hasVersion && hasProjectType
    this.submitButtonTarget.disabled = !shouldEnable
  }

  updateResetButtonState() {
    if (!this.hasResetButtonTarget) return

    const shouldEnable = Boolean(this.currentUpload || this.isUploadComplete)
    if (shouldEnable) {
      this.resetButtonTarget.classList.remove('hidden')
    } else {
      this.resetButtonTarget.classList.add('hidden')
    }
  }

  handleFormSubmit(e) {
    // If a file was selected, wait for upload to complete
    if (this.fuId && !this.isUploadComplete && this.currentUpload && !this.currentUpload.aborted) {
      e.preventDefault()
      if (this.hasStatusTarget) {
        this.statusTarget.textContent = 'Please wait for the upload to complete...'
        this.statusTarget.classList.remove('text-gray-600', 'text-green-600')
        this.statusTarget.classList.add('text-yellow-600')
      }
      return false
    }
    // Otherwise, allow form to submit normally - don't prevent default
    // The form will submit and follow the server redirect
  }

  async downloadFromUrl() {
    if (!this.hasUrlInputTarget || !this.urlInputTarget.value) {
      alert('Please enter a valid URL')
      return
    }

    let url = this.urlInputTarget.value.trim()
    
    // Auto-add protocol if missing
    if (url && !url.match(/^https?:\/\//i)) {
      url = 'https://' + url
    }
    
    // Basic URL validation
    try {
      new URL(url)
    } catch (e) {
      alert('Please enter a valid URL')
      return
    }

    if (this.hasDownloadUrlButtonTarget) {
      this.downloadUrlButtonTarget.disabled = true
      // Ensure spinner animation is available
      this.ensureSpinnerAnimation()
      this.downloadUrlButtonTarget.innerHTML = `
        <span class="inline-flex items-center gap-2">
          <svg style="width: 16px; height: 16px; animation: spin 1s linear infinite;" fill="none" viewBox="0 0 24 24">
            <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566" opacity="0.25"/>
            <circle cx="12" cy="12" r="8" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-dasharray="12.566" stroke-dashoffset="12.566">
              <animate attributeName="stroke-dashoffset" dur="1.5s" values="12.566;0;12.566" repeatCount="indefinite"/>
            </circle>
          </svg>
          Downloading...
        </span>
      `
    }

    if (this.hasStatusTarget) {
      this.statusTarget.textContent = 'Downloading file from URL...'
      this.statusTarget.classList.remove('text-gray-600', 'text-green-600', 'text-red-600')
      this.statusTarget.classList.add('text-yellow-600')
    }

    try {
      const organismField = this.form?.querySelector('[name="project[organism_id]"]')
      const versionField = this.form?.querySelector('[name="project[version_id]"]')
      
      const requestBody = { url: url }
      
      if (organismField && organismField.value) {
        requestBody.organism_id = parseInt(organismField.value)
      }
      if (versionField && versionField.value) {
        requestBody.version_id = parseInt(versionField.value)
      }
      
      const csrfToken = document.querySelector('[name="csrf-token"]')?.content
      const response = await fetch('/fus/download_from_url', {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: JSON.stringify(requestBody)
      })

      const result = await response.json()

      if (!response.ok) {
        throw new Error(result.error || 'Failed to download file from URL')
      }

      this.fuId = result.fu_id
      this.isUploadComplete = true
      this.updateResetButtonState()
      
      // Extract filename from URL or use default
      try {
        const urlObj = new URL(url)
        const pathParts = urlObj.pathname.split('/').filter(p => p)
        const filename = pathParts[pathParts.length - 1] || 'downloaded_file'
        this.originalFilename = filename
        const lastDotIndex = this.originalFilename.lastIndexOf('.')
        if (lastDotIndex > 0) {
          this.originalFilename = this.originalFilename.substring(0, lastDotIndex)
        }
      } catch (e) {
        this.originalFilename = 'downloaded_file'
      }

      if (this.hasInputFilenameTarget) {
        this.inputFilenameTarget.value = result.filename || 'downloaded_file'
      }

      if (this.hasStatusTarget) {
        this.statusTarget.textContent = 'Download complete!'
        this.statusTarget.classList.remove('text-gray-600', 'text-yellow-600', 'text-red-600')
        this.statusTarget.classList.add('text-green-600')
      }

      // Subscribe to preparsing updates
      if (this.fuId) {
        this.subscribeToPreparsing(this.fuId)
      }

      this.displayUploadSuccess('downloaded', result.filename || this.originalFilename || 'downloaded file', result.size)
      this.showPreparsingPanel()
      this.setPreparsingStatus('Download complete. Preparsing will start automatically.', 'info', true)
      this.checkSubmitButton()

    } catch (error) {
      console.error('Error downloading from URL:', error)
      if (this.hasStatusTarget) {
        this.statusTarget.textContent = `Download failed: ${error.message}`
        this.statusTarget.classList.remove('text-gray-600', 'text-green-600', 'text-yellow-600')
        this.statusTarget.classList.add('text-red-600')
      }
    } finally {
      if (this.hasDownloadUrlButtonTarget) {
        this.downloadUrlButtonTarget.disabled = false
        this.downloadUrlButtonTarget.textContent = 'Download'
      }
    }
  }

  buildParsingParametersUI() {
    const delimiterOptions = [
      { value: '', label: 'Tabulation' },
      { value: ' ', label: 'Space' },
      { value: ';', label: 'Semicolon' },
      { value: ',', label: 'Comma' }
    ]
    
    const geneNameColOptions = [
      { value: 'first', label: 'First column' },
      { value: 'none', label: 'None' },
      { value: 'last', label: 'Last column' }
    ]
    
    const currentDelimiter = this.parsingParams.delimiter || ''
    const currentGeneNameCol = this.parsingParams.gene_name_col || 'first'
    const currentHasHeader = this.parsingParams.has_header !== false
    
    let delimiterOptionsHtml = delimiterOptions.map(opt => 
      `<option value="${this.escapeHtml(opt.value)}" ${opt.value === currentDelimiter ? 'selected' : ''}>${this.escapeHtml(opt.label)}</option>`
    ).join('')
    
    let geneNameColOptionsHtml = geneNameColOptions.map(opt => 
      `<option value="${this.escapeHtml(opt.value)}" ${opt.value === currentGeneNameCol ? 'selected' : ''}>${this.escapeHtml(opt.label)}</option>`
    ).join('')
    
    return `
      <div class="rounded-lg border border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-900/20 p-4 mb-4">
        <h3 class="text-base font-semibold text-blue-900 dark:text-blue-200 mb-4">Parsing parameters</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label for="parsing-delimiter" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Delimiter
            </label>
            <select 
              id="parsing-delimiter" 
              class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white text-sm"
              data-file-upload-target="delimiterSelect"
            >
              ${delimiterOptionsHtml}
            </select>
            <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">Character delimiting the fields in the input text file.</p>
          </div>
          
          <div>
            <label for="parsing-gene-name-col" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Gene name column
            </label>
            <select 
              id="parsing-gene-name-col" 
              class="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white text-sm"
              data-file-upload-target="geneNameColSelect"
            >
              ${geneNameColOptionsHtml}
            </select>
          </div>
        </div>
        
        <div class="mt-4">
          <label class="flex items-center">
            <input 
              type="checkbox" 
              id="parsing-has-header" 
              class="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              ${currentHasHeader ? 'checked' : ''}
              data-file-upload-target="hasHeaderCheckbox"
            />
            <span class="ml-2 text-sm text-gray-700 dark:text-gray-300">
              Cell names header is present in line 1
            </span>
          </label>
          <p class="mt-1 ml-6 text-xs text-gray-500 dark:text-gray-400">
            If the cell names header is not present, cell names are generated and contain the column index.
          </p>
        </div>
      </div>
    `
  }

  setupParsingParametersHandlers() {
    const delimiterSelect = this.preparsingResultTarget?.querySelector('#parsing-delimiter')
    const geneNameColSelect = this.preparsingResultTarget?.querySelector('#parsing-gene-name-col')
    const hasHeaderCheckbox = this.preparsingResultTarget?.querySelector('#parsing-has-header')
    
    if (delimiterSelect) {
      delimiterSelect.addEventListener('change', (e) => {
        this.parsingParams.delimiter = e.target.value
        this.updatePreparsingWithParams()
      })
    }
    
    if (geneNameColSelect) {
      geneNameColSelect.addEventListener('change', (e) => {
        this.parsingParams.gene_name_col = e.target.value
        this.updatePreparsingWithParams()
      })
    }
    
    if (hasHeaderCheckbox) {
      hasHeaderCheckbox.addEventListener('change', (e) => {
        this.parsingParams.has_header = e.target.checked
        this.updatePreparsingWithParams()
      })
    }
  }

  async updatePreparsingWithParams() {
    if (!this.fuId) return
    
    this.setPreparsingStatus('Updating preparsing with new parameters...', 'info', true)
    
    try {
      const organismField = this.form?.querySelector('[name="project[organism_id]"]')
      const versionField = this.form?.querySelector('[name="project[version_id]"]')
      
      const requestBody = {
        // No sel parameter for text file re-parsing with parameters only
        delimiter: this.parsingParams.delimiter !== undefined ? this.parsingParams.delimiter : '',
        gene_name_col: this.parsingParams.gene_name_col || 'first',
        has_header: this.parsingParams.has_header !== false ? '1' : '0'
      }
      
      if (organismField && organismField.value) {
        requestBody.organism_id = parseInt(organismField.value)
      }
      if (versionField && versionField.value) {
        requestBody.version_id = parseInt(versionField.value)
      }
      
      console.log('[FileUpload] updatePreparsingWithParams - versionField:', versionField)
      console.log('[FileUpload] updatePreparsingWithParams - versionField.value:', versionField?.value)
      console.log('[FileUpload] updatePreparsingWithParams - requestBody:', requestBody)
      
      const csrfToken = document.querySelector('[name="csrf-token"]')?.content
      const response = await fetch(`/fus/${this.fuId}/rerun_preparsing`, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': csrfToken,
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: JSON.stringify(requestBody)
      })
      
      if (!response.ok) {
        const error = await response.json().catch(() => ({ error: 'Failed to update preparsing' }))
        throw new Error(error.error || 'Failed to update preparsing')
      }
      
      // Always re-subscribe when rerunning preparsing to ensure fresh connection
      // This ensures we receive updates even if the previous subscription was disconnected
      if (this.fuId) {
        console.log('[FileUpload] Re-subscribing to preparsing websocket for rerun with new parameters')
        this.subscribeToPreparsing(this.fuId)
        // Start polling as fallback in case websocket misses the update
        this.startPreparsingStatusPoll(this.fuId)
      }
      
      // The websocket will handle the update when preparsing completes
      this.setPreparsingStatus('Re-preparsing with new parameters. Please wait...', 'info', true)
    } catch (error) {
      console.error('Error updating preparsing:', error)
      this.setPreparsingStatus(`Error: ${error.message}`, 'error')
    }
  }

  resetForm() {
    // Cancel any ongoing upload first
    if (this.currentUpload) {
      if (this.currentUpload.abort) {
        this.currentUpload.abort()
      } else {
        // If it's a plain object (file selected but upload not started), just mark it as aborted
        this.currentUpload.aborted = true
      }
      this.currentUpload = null
    }

    // Reset file upload state
    if (this.hasFileInputTarget) {
      this.fileInputTarget.value = ''
    }
    
    if (this.hasUrlInputTarget) {
      this.urlInputTarget.value = ''
    }

    // Clear progress display
    if (this.hasProgressTarget) {
      this.progressTarget.classList.add('hidden')
    }
    
    if (this.hasFilenameTarget) {
      this.filenameTarget.textContent = ''
    }
    
    if (this.hasPercentageTarget) {
      this.percentageTarget.textContent = '0%'
    }
    
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = '0%'
    }
    
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = ''
      this.statusTarget.classList.remove('text-gray-600', 'text-green-600', 'text-red-600', 'text-yellow-600')
      this.statusTarget.classList.add('text-gray-600')
    }

    if (this.hasInputFilenameTarget) {
      this.inputFilenameTarget.value = ''
    }

    // Reset all instance variables
    this.fuId = null
    this.isUploadComplete = false
    this.originalFilename = null
    this.isPreparsingComplete = false
    this.hasMatrixData = false
    this.currentDetectedFormat = null
    this.selectedDatasetIndex = null
    this.selectedDatasetName = null
    this.selectedFileIndex = null
    this.selectedFileName = null
    this.archiveFilesData = null
    this.cameFromArchive = false
    this.projectNameTouched = false
    
    // Reset preparsing state
    this.resetPreparsingState()
    
    // Unsubscribe from preparsing updates
    this.teardownPreparsingSubscription()

    // Reset parsing parameters
    this.parsingParams = {
      delimiter: '',
      gene_name_col: 'first',
      has_header: true
    }

    // Reset form fields manually (only specific fields, NOT organism_id or version_id)
    if (this.form) {
      // Reset project name field
      const nameField = this.form.querySelector('[name="project[name]"]')
      if (nameField) {
        nameField.value = ''
      }
      
      // Reset project type field
      const projectTypeField = this.form.querySelector('[name="project[project_type_id]"]')
      if (projectTypeField) {
        projectTypeField.value = ''
      }
      
      // Note: We intentionally do NOT reset organism_id or version_id
      // as these are needed for preparsing and should maintain their values
    }

    // Reset form to initial state visually
    if (this.hasDropzoneTarget) {
      this.dropzoneTarget.classList.remove('hidden')
    }

    this.showUploadInputs()
    // Update submit button state
    this.checkSubmitButton()
    this.updateResetButtonState()
  }
}

