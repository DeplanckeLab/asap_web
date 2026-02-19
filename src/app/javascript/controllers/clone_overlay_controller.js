import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  showOverlay() {
    const existing = document.getElementById('clone-loading-overlay')
    if (existing) existing.remove()

    const overlay = document.createElement('div')
    overlay.id = 'clone-loading-overlay'
    overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background-color:rgba(0,0,0,0.5);z-index:9999;display:flex;flex-direction:column;align-items:center;justify-content:center;'
    overlay.innerHTML = `
      <div style="background:white;border-radius:12px;padding:32px 48px;text-align:center;max-width:480px;">
        <svg style="width:48px;height:48px;margin:0 auto 16px;color:#3b82f6;" viewBox="0 0 24 24" fill="none">
          <circle cx="12" cy="12" r="10" stroke="currentColor" stroke-width="2" opacity="0.2"/>
          <path d="M12 2a10 10 0 0 1 10 10" stroke="currentColor" stroke-width="2" stroke-linecap="round">
            <animateTransform attributeName="transform" type="rotate" from="0 12 12" to="360 12 12" dur="1s" repeatCount="indefinite"/>
          </path>
        </svg>
        <p style="font-size:16px;font-weight:500;color:#1f2937;margin:0;">Cloning project...</p>
        <p style="font-size:13px;color:#6b7280;margin-top:8px;">Please wait, this may take a moment.</p>
      </div>
    `
    document.body.appendChild(overlay)
  }
}
