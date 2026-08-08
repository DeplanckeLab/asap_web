export const CHECKPOINT_THUMBNAIL_MAX_WIDTH = 360
export const CHECKPOINT_THUMBNAIL_JPEG_QUALITY = 0.72
export const CHECKPOINT_THUMB_CLASS = 'checkpoint-thumb'
export const CHECKPOINT_THUMB_PREVIEW_ID = 'checkpoint-thumb-hover-preview'

let checkpointThumbHoverInstalled = false
let checkpointThumbHoverActiveImg = null

function loadImageFromDataUrl(dataUrl) {
  return new Promise((resolve, reject) => {
    const image = new Image()
    image.onload = () => resolve(image)
    image.onerror = (error) => reject(error)
    image.src = dataUrl
  })
}

export function isCheckpointThumbnailDataUrl(value) {
  return typeof value === 'string' && value.startsWith('data:image/jpeg;base64,')
}

function ensureCheckpointThumbHoverPreviewEl() {
  let preview = document.getElementById(CHECKPOINT_THUMB_PREVIEW_ID)
  if (preview) return preview

  preview = document.createElement('div')
  preview.id = CHECKPOINT_THUMB_PREVIEW_ID
  preview.setAttribute('aria-hidden', 'true')
  preview.className = 'checkpoint-thumb-hover-preview'
  preview.innerHTML = '<img alt="" />'
  document.body.appendChild(preview)
  return preview
}

function hideCheckpointThumbHoverPreview() {
  checkpointThumbHoverActiveImg = null
  const preview = document.getElementById(CHECKPOINT_THUMB_PREVIEW_ID)
  if (!preview) return
  preview.classList.remove('is-visible')
  const img = preview.querySelector('img')
  if (img) img.removeAttribute('src')
}

function positionCheckpointThumbHoverPreview(anchorImg) {
  const preview = ensureCheckpointThumbHoverPreviewEl()
  const previewImg = preview.querySelector('img')
  if (!previewImg || !anchorImg) return

  const gap = 8
  const margin = 8
  const maxWidth = Math.min(CHECKPOINT_THUMBNAIL_MAX_WIDTH, window.innerWidth - margin * 2)
  previewImg.style.maxWidth = `${maxWidth}px`

  const anchorRect = anchorImg.getBoundingClientRect()
  const previewRect = preview.getBoundingClientRect()
  const previewWidth = previewRect.width || Math.min(maxWidth, anchorRect.width * 4)
  const previewHeight = previewRect.height || Math.round(previewWidth * 0.75)

  let left = anchorRect.left
  left = Math.max(margin, Math.min(left, window.innerWidth - previewWidth - margin))

  const spaceBelow = window.innerHeight - anchorRect.bottom - gap - margin
  const spaceAbove = anchorRect.top - gap - margin
  let top
  if (spaceBelow >= previewHeight || spaceBelow >= spaceAbove) {
    top = anchorRect.bottom + gap
  } else {
    top = anchorRect.top - previewHeight - gap
  }
  top = Math.max(margin, Math.min(top, window.innerHeight - previewHeight - margin))

  preview.style.left = `${Math.round(left)}px`
  preview.style.top = `${Math.round(top)}px`
}

function showCheckpointThumbHoverPreview(anchorImg) {
  if (!anchorImg || !isCheckpointThumbnailDataUrl(anchorImg.currentSrc || anchorImg.src)) return

  checkpointThumbHoverActiveImg = anchorImg
  const preview = ensureCheckpointThumbHoverPreviewEl()
  const previewImg = preview.querySelector('img')
  const src = anchorImg.currentSrc || anchorImg.src
  if (previewImg.getAttribute('src') !== src) {
    previewImg.onload = () => {
      if (checkpointThumbHoverActiveImg === anchorImg) {
        positionCheckpointThumbHoverPreview(anchorImg)
      }
    }
    previewImg.src = src
  }
  preview.classList.add('is-visible')
  positionCheckpointThumbHoverPreview(anchorImg)
}

export function installCheckpointThumbnailHoverPreview() {
  if (checkpointThumbHoverInstalled || typeof document === 'undefined') return
  checkpointThumbHoverInstalled = true

  document.addEventListener('pointerover', (event) => {
    const target = event.target
    if (!(target instanceof Element)) return
    const thumb = target.closest(`.${CHECKPOINT_THUMB_CLASS}`)
    if (!(thumb instanceof HTMLImageElement)) return
    showCheckpointThumbHoverPreview(thumb)
  })

  document.addEventListener('pointerout', (event) => {
    const target = event.target
    if (!(target instanceof Element)) return
    if (!target.classList?.contains(CHECKPOINT_THUMB_CLASS)) return
    const related = event.relatedTarget
    if (related instanceof Element && related.closest(`.${CHECKPOINT_THUMB_CLASS}`) === target) return
    if (checkpointThumbHoverActiveImg === target) {
      hideCheckpointThumbHoverPreview()
    }
  })

  document.addEventListener('scroll', () => {
    if (checkpointThumbHoverActiveImg) hideCheckpointThumbHoverPreview()
  }, true)

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') hideCheckpointThumbHoverPreview()
  })

  document.addEventListener('turbo:before-cache', hideCheckpointThumbHoverPreview)
  document.addEventListener('turbo:before-render', hideCheckpointThumbHoverPreview)
}

export function canvasToJpegThumbnailDataUrl(
  sourceCanvas,
  {
    maxWidth = CHECKPOINT_THUMBNAIL_MAX_WIDTH,
    quality = CHECKPOINT_THUMBNAIL_JPEG_QUALITY
  } = {}
) {
  if (!sourceCanvas || !sourceCanvas.width || !sourceCanvas.height) {
    return null
  }

  const scale = Math.min(1, maxWidth / sourceCanvas.width)
  const width = Math.max(1, Math.round(sourceCanvas.width * scale))
  const height = Math.max(1, Math.round(sourceCanvas.height * scale))
  const output = document.createElement('canvas')
  output.width = width
  output.height = height
  const ctx = output.getContext('2d')
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, width, height)
  ctx.drawImage(sourceCanvas, 0, 0, width, height)
  return output.toDataURL('image/jpeg', quality)
}

export async function dataUrlToJpegThumbnail(
  dataUrl,
  {
    maxWidth = CHECKPOINT_THUMBNAIL_MAX_WIDTH,
    quality = CHECKPOINT_THUMBNAIL_JPEG_QUALITY
  } = {}
) {
  if (!dataUrl || typeof dataUrl !== 'string') {
    return null
  }

  const image = await loadImageFromDataUrl(dataUrl)
  const scale = Math.min(1, maxWidth / image.width)
  const width = Math.max(1, Math.round(image.width * scale))
  const height = Math.max(1, Math.round(image.height * scale))
  const output = document.createElement('canvas')
  output.width = width
  output.height = height
  const ctx = output.getContext('2d')
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, width, height)
  ctx.drawImage(image, 0, 0, width, height)
  return output.toDataURL('image/jpeg', quality)
}
