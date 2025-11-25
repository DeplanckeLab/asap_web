import { Controller } from "@hotwired/stimulus"

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
    "submitButton"
  ]

  static values = {
    chunkSize: { type: Number, default: 5 * 1024 * 1024 } // 5MB
  }

  connect() {
    this.currentUpload = null
    this.isUploadComplete = false
    this.fuId = null

    // Set up global drag/drop prevention immediately
    this.setupGlobalDragDropPrevention()

    // Set up dropzone-specific handlers
    this.setupDropzoneHandlers()
    
    // Set up file input handler
    if (this.hasFileInputTarget) {
      this.fileInputTarget.addEventListener('change', this.handleFileSelect.bind(this))
    }

    // Set up form submission handler
    this.form = this.element.closest('form')
    if (this.form) {
      this.form.addEventListener('submit', this.handleFormSubmit.bind(this))
    }
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

    // Prevent dragenter/dragover events globally
    this.globalDragHandler = (e) => {
      if (this.isFileDragDrop(e)) {
        e.preventDefault()
        e.stopPropagation()
        return false
      }
    }

    // Handle drop events globally - ALWAYS prevent default
    this.globalDropHandler = (e) => {
      if (this.isFileDragDrop(e)) {
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
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = true
    }
    this.isUploadComplete = false
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
    
    this.fuId = null
    this.currentUpload = { file, aborted: false }
    
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
        const resumePercent = ((resumeSize / resumeInfo.total_size) * 100).toFixed(1)
        
        if (confirm(`Found an incomplete upload (${resumePercent}% complete). Would you like to resume from where you left off?`)) {
          this.updateProgress(resumeSize, resumeInfo.total_size)
          if (this.hasStatusTarget) {
            this.statusTarget.textContent = `Resuming upload from ${this.formatBytes(resumeSize)}...`
          }
        } else {
          this.fuId = null
        }
      }
      
      await this.uploadFileInChunks(file)
      
      if (!this.currentUpload.aborted) {
        if (this.hasInputFilenameTarget) {
          this.inputFilenameTarget.value = file.name
        }
        if (this.hasStatusTarget) {
          this.statusTarget.textContent = 'Upload complete!'
          this.statusTarget.classList.remove('text-gray-600')
          this.statusTarget.classList.add('text-green-600')
        }
        this.isUploadComplete = true
        if (this.hasSubmitButtonTarget) {
          this.submitButtonTarget.disabled = false
        }
      }
    } catch (error) {
      if (!this.currentUpload.aborted && this.hasStatusTarget) {
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
          if (this.hasSubmitButtonTarget) {
            this.submitButtonTarget.disabled = false
          }
          return
        }
        this.updateProgress(uploadedSize, file.size)
      }
    }
    
    // Upload chunks sequentially
    for (let chunkIndex = startChunkIndex; chunkIndex < totalChunks; chunkIndex++) {
      if (this.currentUpload.aborted) {
        throw new Error('Upload cancelled')
      }
      
      const start = chunkIndex * chunkSize
      const end = Math.min(start + chunkSize, file.size)
      const chunk = file.slice(start, end)
      
      const result = await this.uploadChunk(chunk, chunkIndex, totalChunks, file.size)
      
      if (result.fu_id && !this.fuId) {
        this.fuId = result.fu_id
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
    const percentage = Math.round((uploaded / total) * 100)
    
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
  }
}

