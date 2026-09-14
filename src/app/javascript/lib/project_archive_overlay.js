const OVERLAY_ROOT_ID = 'asap-live-archive-overlay'
const ARCHIVE_OVERLAY_EVENT = 'asap:project-archive-overlay'
const METADATA_ONLY_VIEWS = new Set(['summary', 'settings', 'access', 'annotations'])

function projectMainEl() {
  return document.getElementById('asap-project-main')
}

function currentViewName() {
  return new URL(window.location.href).searchParams.get('view') || ''
}

function isMetadataOnlyView() {
  const view = currentViewName()
  return METADATA_ONLY_VIEWS.has(view)
}

function unarchiveUrl() {
  const url = new URL(window.location.href)
  url.searchParams.set('force_unarchive', '1')
  return url.toString()
}

function summaryUrl(projectId) {
  return `/projects/${projectId}?view=summary`
}

function dispatchOverlayState(active, status, projectId) {
  document.dispatchEvent(new CustomEvent(ARCHIVE_OVERLAY_EVENT, {
    detail: { active: !!active, status: status || null, projectId: projectId || null }
  }))
}

function ensureOverlayRoot() {
  const main = projectMainEl()
  if (!main) return null

  let root = document.getElementById(OVERLAY_ROOT_ID)
  if (root) return root

  root = document.createElement('div')
  root.id = OVERLAY_ROOT_ID
  root.setAttribute('data-guided-tour', 'project-live-archive-overlay')
  root.style.cssText = [
    'position:absolute',
    'inset:0',
    'z-index:40',
    'display:flex',
    'flex-direction:column',
    'align-items:center',
    'justify-content:center',
    'background-color:#f9fafb',
    'padding:40px'
  ].join(';')
  main.appendChild(root)
  return root
}

function archivingMarkup() {
  return `
    <div style="max-width:640px;width:100%;text-align:center;">
      <h2 style="font-size:24px;font-weight:600;color:#374151;margin-bottom:16px;">Project Is Being Archived</h2>
      <p style="font-size:16px;color:#6b7280;margin-bottom:24px;line-height:1.6;">
        Project files are being packed and uploaded to storage. Visualization, analysis, data, and compliance views stay unavailable until archiving finishes.
      </p>
      <div style="display:flex;align-items:center;justify-content:center;margin-bottom:14px;">
        <div style="width:22px;height:22px;border:3px solid #d1d5db;border-top-color:#3b82f6;border-radius:50%;animation:asap-live-archive-spin 1s linear infinite;"></div>
      </div>
      <style>
        @keyframes asap-live-archive-spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      </style>
      <p style="font-size:14px;color:#4b5563;margin-bottom:12px;line-height:1.6;">Archiving project files...</p>
      <div style="width:100%;height:10px;background-color:#e5e7eb;border-radius:9999px;overflow:hidden;margin-bottom:16px;">
        <div style="height:100%;width:45%;background-color:#3b82f6;"></div>
      </div>
      <div style="text-align:left;font-size:13px;color:#6b7280;line-height:1.7;margin-bottom:14px;">
        <div>1. Creating archive on the server</div>
        <div>2. Uploading archive to storage</div>
        <div>3. Verifying archive integrity</div>
      </div>
      <p style="font-size:13px;color:#6b7280;line-height:1.6;">
        Summary and other metadata views remain available from the project tabs.
      </p>
    </div>
  `
}

function archivedMarkup(projectId) {
  const restoreHref = unarchiveUrl()
  const summaryHref = summaryUrl(projectId)
  return `
    <div style="max-width:640px;width:100%;text-align:center;">
      <h2 style="font-size:24px;font-weight:600;color:#374151;margin-bottom:16px;">Project Is Archived</h2>
      <p style="font-size:16px;color:#6b7280;margin-bottom:24px;line-height:1.6;">
        Project files were moved to storage while this page was open. Visualization, analysis, data, and compliance views cannot load files until the project is unarchived.
      </p>
      <div style="display:flex;flex-wrap:wrap;gap:12px;justify-content:center;margin-bottom:16px;">
        <a href="${restoreHref}" data-turbo="false"
           style="display:inline-flex;align-items:center;justify-content:center;padding:10px 18px;border-radius:8px;background-color:#2563eb;color:#ffffff;font-size:14px;font-weight:600;text-decoration:none;">
          Unarchive project
        </a>
        <a href="${summaryHref}"
           style="display:inline-flex;align-items:center;justify-content:center;padding:10px 18px;border-radius:8px;background-color:#ffffff;color:#374151;font-size:14px;font-weight:600;text-decoration:none;border:1px solid #d1d5db;">
          Open summary
        </a>
      </div>
      <p style="font-size:13px;color:#6b7280;line-height:1.6;">
        Summary and other metadata views remain available without restoring files.
      </p>
    </div>
  `
}

export function showProjectArchiveOverlay(projectId, status) {
  // Metadata-only tabs remain usable while archived; do not cover them.
  if (isMetadataOnlyView()) return

  const root = ensureOverlayRoot()
  if (!root) {
    console.warn('[ProjectArchiveOverlay] asap-project-main not found; cannot show overlay')
    return
  }

  if (status === 'archiving') {
    root.innerHTML = archivingMarkup()
    root.dataset.archiveStatus = 'archiving'
    dispatchOverlayState(true, 'archiving', projectId)
    return
  }

  if (status === 'archived') {
    root.innerHTML = archivedMarkup(projectId)
    root.dataset.archiveStatus = 'archived'
    dispatchOverlayState(true, 'archived', projectId)
  }
}

export function hideProjectArchiveOverlay(projectId = null) {
  const root = document.getElementById(OVERLAY_ROOT_ID)
  if (root) root.remove()
  dispatchOverlayState(false, null, projectId)
}

export function handleProjectArchiveBroadcast(data, projectId) {
  if (!data || !projectId) return false
  if (data.project_id != null && Number(data.project_id) !== Number(projectId)) return false

  if (data.archive_status === 'archiving') {
    showProjectArchiveOverlay(projectId, 'archiving')
    return true
  }

  if (data.project_archived === true || data.archive_status === 'archived') {
    showProjectArchiveOverlay(projectId, 'archived')
    return true
  }

  if (data.archive_status === 'failed') {
    hideProjectArchiveOverlay(projectId)
    return true
  }

  return false
}

export { ARCHIVE_OVERLAY_EVENT }
