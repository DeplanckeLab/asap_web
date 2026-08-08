export const CHECKPOINT_THUMBNAIL_MAX_WIDTH = 360
export const CHECKPOINT_THUMBNAIL_JPEG_QUALITY = 0.72

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
