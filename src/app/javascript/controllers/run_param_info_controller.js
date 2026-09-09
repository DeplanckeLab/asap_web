import { Controller } from "@hotwired/stimulus"
import { showPipelineRunsPanel } from "controllers/pipeline_runs_panel"

const POPOVER_ID = "run-param-info-popover"

let lastAnchorElement = null
let boundOutsideClick = null
let boundEscape = null
const dialogsWithParamInfoCloseBound = new WeakSet()

function isRunParamInfoPopoverOpen(popover) {
  return !!(popover && !popover.classList.contains("hidden"))
}

function applyRunParamInfoPosition(popover, viewportLeft, viewportTop) {
  const parent = popover.parentElement
  const inDialog = !!(parent && parent.tagName === "DIALOG")
  let left = viewportLeft
  let top = viewportTop

  if (inDialog) {
    const parentRect = parent.getBoundingClientRect()
    left = viewportLeft - parentRect.left
    top = viewportTop - parentRect.top
    popover.style.setProperty("position", "absolute", "important")
  } else {
    popover.style.setProperty("position", "fixed", "important")
  }

  popover.style.setProperty("margin", "0", "important")
  popover.style.setProperty("inset", "auto", "important")
  popover.style.setProperty("right", "auto", "important")
  popover.style.setProperty("bottom", "auto", "important")
  popover.style.setProperty("left", `${left}px`, "important")
  popover.style.setProperty("top", `${top}px`, "important")
  popover.style.transform = "none"
  popover.style.zIndex = "80"
}

function makeRunParamInfoDraggable(popover, handle) {
  if (popover.dataset.dragBound === "1") return
  popover.dataset.dragBound = "1"

  let isDragging = false
  let startX = 0
  let startY = 0
  let initialLeft = 0
  let initialTop = 0
  let activePointerId = null

  const onPointerMove = (event) => {
    if (!isDragging) return
    if (activePointerId !== null && event.pointerId !== activePointerId) return
    event.preventDefault()

    let newLeft = initialLeft + (event.clientX - startX)
    let newTop = initialTop + (event.clientY - startY)
    const width = popover.offsetWidth
    const height = popover.offsetHeight
    newLeft = Math.max(0, Math.min(newLeft, window.innerWidth - width))
    newTop = Math.max(0, Math.min(newTop, window.innerHeight - height))
    applyRunParamInfoPosition(popover, newLeft, newTop)
  }

  const endDrag = (event) => {
    if (!isDragging) return
    if (activePointerId !== null && event.pointerId !== activePointerId) return

    isDragging = false
    activePointerId = null
    popover.style.transition = ""
    handle.style.cursor = "move"
    document.body.style.userSelect = ""
    document.body.style.cursor = ""

    try {
      if (typeof handle.hasPointerCapture === "function" && handle.hasPointerCapture(event.pointerId)) {
        handle.releasePointerCapture(event.pointerId)
      }
    } catch (_error) {
      // ignore
    }

    window.removeEventListener("pointermove", onPointerMove, true)
    window.removeEventListener("pointerup", endDrag, true)
    window.removeEventListener("pointercancel", endDrag, true)
  }

  handle.addEventListener("pointerdown", (event) => {
    if (event.button !== undefined && event.button !== 0) return
    if (event.target.closest('button[aria-label="Close"]')) return

    isDragging = true
    activePointerId = event.pointerId
    startX = event.clientX
    startY = event.clientY

    const rect = popover.getBoundingClientRect()
    initialLeft = rect.left
    initialTop = rect.top
    applyRunParamInfoPosition(popover, initialLeft, initialTop)

    popover.style.transition = "none"
    handle.style.cursor = "grabbing"
    document.body.style.userSelect = "none"
    document.body.style.cursor = "grabbing"

    try {
      handle.setPointerCapture(event.pointerId)
    } catch (_error) {
      // ignore
    }

    window.addEventListener("pointermove", onPointerMove, true)
    window.addEventListener("pointerup", endDrag, true)
    window.addEventListener("pointercancel", endDrag, true)

    event.preventDefault()
    event.stopPropagation()
  })
}

function closeRunParamInfoPopover() {
  const popover = document.getElementById(POPOVER_ID)
  if (!popover) return

  popover.classList.add("hidden")
  popover.dataset.openFor = ""
  if (popover.parentElement && popover.parentElement !== document.body) {
    document.body.appendChild(popover)
  }
  unbindRunParamInfoDismissHandlers()
}

function unbindRunParamInfoDismissHandlers() {
  if (boundOutsideClick) {
    document.removeEventListener("pointerdown", boundOutsideClick, true)
    boundOutsideClick = null
  }
  if (boundEscape) {
    document.removeEventListener("keydown", boundEscape, true)
    boundEscape = null
  }
}

function bindRunParamInfoDismissHandlers() {
  if (boundOutsideClick) return

  boundOutsideClick = (event) => {
    const popover = document.getElementById(POPOVER_ID)
    if (!isRunParamInfoPopoverOpen(popover)) return
    if (popover.contains(event.target)) return
    if (event.target.closest('[data-controller~="run-param-info"]')) return
    closeRunParamInfoPopover()
  }

  boundEscape = (event) => {
    if (event.key !== "Escape") return
    const popover = document.getElementById(POPOVER_ID)
    if (!isRunParamInfoPopoverOpen(popover)) return
    event.preventDefault()
    event.stopPropagation()
    closeRunParamInfoPopover()
  }

  // pointerdown avoids fighting with drag gesture click synthesis
  document.addEventListener("pointerdown", boundOutsideClick, true)
  document.addEventListener("keydown", boundEscape, true)
}

function closestOpenDialog(element) {
  const dialog = element?.closest?.("dialog")
  if (!dialog) return null
  if (typeof dialog.open === "boolean" && !dialog.open) return null
  return dialog
}

function mountRunParamInfoPopover(popover, anchorElement) {
  // Modal <dialog> uses the browser top layer; mount inside it so the
  // badge popover is not greyed by the dialog backdrop.
  const openDialog = closestOpenDialog(anchorElement)
  const mountParent = openDialog || document.body
  if (popover.parentElement !== mountParent) {
    mountParent.appendChild(popover)
  }

  if (openDialog) {
    openDialog.style.overflow = "visible"
    if (!dialogsWithParamInfoCloseBound.has(openDialog)) {
      dialogsWithParamInfoCloseBound.add(openDialog)
      openDialog.addEventListener("close", () => {
        closeRunParamInfoPopover()
      })
    }
  }
}

function ensureRunParamInfoPopover() {
  let popover = document.getElementById(POPOVER_ID)
  if (popover && (popover.hasAttribute("popover") || popover.dataset.dragVersion !== "3")) {
    try {
      if (typeof popover.hidePopover === "function" && popover.hasAttribute("popover") && popover.matches(":popover-open")) {
        popover.hidePopover()
      }
    } catch (_error) {
      // ignore
    }
    popover.remove()
    popover = null
  }
  if (popover) return popover

  popover = document.createElement("div")
  popover.id = POPOVER_ID
  popover.dataset.dragVersion = "3"
  popover.className = "hidden fixed z-[80] w-[min(28rem,92vw)] max-h-[min(24rem,70vh)] bg-white rounded-lg border border-gray-200 shadow-xl flex flex-col overflow-hidden"
  popover.setAttribute("role", "dialog")
  popover.setAttribute("aria-modal", "false")

  popover.innerHTML = `
    <div data-run-param-info-target="header" class="flex items-start justify-between gap-2 px-3 py-2 border-b border-gray-200 bg-gray-50 cursor-move select-none">
      <div class="flex items-start gap-2 min-w-0 flex-1">
        <div class="text-gray-400 mt-0.5 flex-shrink-0" aria-hidden="true">
          <svg width="14" height="14" viewBox="0 0 12 12" fill="currentColor"><circle cx="2" cy="2" r="1"/><circle cx="6" cy="2" r="1"/><circle cx="10" cy="2" r="1"/><circle cx="2" cy="6" r="1"/><circle cx="6" cy="6" r="1"/><circle cx="10" cy="6" r="1"/><circle cx="2" cy="10" r="1"/><circle cx="6" cy="10" r="1"/><circle cx="10" cy="10" r="1"/></svg>
        </div>
        <h4 data-run-param-info-target="title" class="text-sm font-semibold text-gray-900 pr-2"></h4>
      </div>
      <button type="button" data-run-param-info-target="closeButton" class="text-gray-400 hover:text-gray-600 leading-none p-1 cursor-pointer flex-shrink-0" aria-label="Close">
        <span class="text-lg">&times;</span>
      </button>
    </div>
    <div class="px-3 py-2 overflow-y-auto text-xs space-y-2">
      <div>
        <div class="font-semibold text-gray-700">Name</div>
        <div data-run-param-info-target="nameField" class="font-mono text-gray-600 break-all"></div>
      </div>
      <div>
        <div class="font-semibold text-gray-700">Label</div>
        <div data-run-param-info-target="labelField" class="text-gray-600 break-words"></div>
      </div>
      <div data-run-param-info-target="descriptionBlock" class="hidden">
        <div class="font-semibold text-gray-700">Description</div>
        <div data-run-param-info-target="descriptionField" class="text-gray-600 break-words"></div>
      </div>
      <div>
        <div class="font-semibold text-gray-700">Value</div>
        <div data-run-param-info-target="valueField" class="mt-1 font-mono text-gray-800 break-all whitespace-pre-wrap select-text"></div>
      </div>
      <div data-run-param-info-target="pipelineBlock" class="hidden pt-1">
        <button type="button" data-run-param-info-target="pipelineButton" class="text-xs font-medium text-blue-700 hover:text-blue-900 underline">
          View pipeline runs
        </button>
      </div>
    </div>
  `

  document.body.appendChild(popover)

  const header = popover.querySelector('[data-run-param-info-target="header"]')
  makeRunParamInfoDraggable(popover, header)

  popover.querySelector('[data-run-param-info-target="closeButton"]').addEventListener("click", (event) => {
    event.preventDefault()
    event.stopPropagation()
    closeRunParamInfoPopover()
  })

  popover.querySelector('[data-run-param-info-target="pipelineButton"]').addEventListener("click", (event) => {
    event.preventDefault()
    event.stopPropagation()

    const annotId = popover.dataset.pipelineAnnotId
    const runId = popover.dataset.pipelineRunId
    const url = popover.dataset.pipelineUrl
    if (!url || (!annotId && !runId)) return

    closeRunParamInfoPopover()

    showPipelineRunsPanel({
      url,
      annotId: annotId || null,
      runId: runId || null,
      anchorElement: lastAnchorElement
    })
  })

  popover.addEventListener("pointerdown", (event) => event.stopPropagation())
  popover.addEventListener("click", (event) => event.stopPropagation())

  return popover
}

export default class extends Controller {
  static values = {
    name: String,
    label: String,
    description: String,
    value: String,
    pipelineAnnotId: Number,
    pipelineRunId: Number,
    pipelineUrl: String
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    this.assignElementId()
    const popover = ensureRunParamInfoPopover()
    if (popover.dataset.openFor === this.element.id && isRunParamInfoPopoverOpen(popover)) {
      closeRunParamInfoPopover()
      return
    }

    this.populatePopover(popover)
    mountRunParamInfoPopover(popover, this.element)
    popover.classList.remove("hidden")
    popover.dataset.openFor = this.element.id
    lastAnchorElement = this.element
    this.positionPopover(popover, event)
    bindRunParamInfoDismissHandlers()
  }

  assignElementId() {
    if (!this.element.id) {
      this.element.id = `run-param-badge-${Math.random().toString(36).slice(2, 10)}`
    }
  }

  populatePopover(popover) {
    const title = popover.querySelector('[data-run-param-info-target="title"]')
    const nameField = popover.querySelector('[data-run-param-info-target="nameField"]')
    const labelField = popover.querySelector('[data-run-param-info-target="labelField"]')
    const descriptionBlock = popover.querySelector('[data-run-param-info-target="descriptionBlock"]')
    const descriptionField = popover.querySelector('[data-run-param-info-target="descriptionField"]')
    const valueField = popover.querySelector('[data-run-param-info-target="valueField"]')
    const pipelineBlock = popover.querySelector('[data-run-param-info-target="pipelineBlock"]')

    title.textContent = this.labelValue || this.nameValue || "Parameter"
    nameField.textContent = this.nameValue || "-"
    labelField.textContent = this.labelValue || "-"

    const description = (this.descriptionValue || "").trim()
    if (description) {
      descriptionBlock.classList.remove("hidden")
      descriptionField.textContent = description
    } else {
      descriptionBlock.classList.add("hidden")
      descriptionField.textContent = ""
    }

    valueField.textContent = this.valueValue || ""

    const hasPipeline = this.hasPipelineUrlValue && (this.hasPipelineAnnotIdValue || this.hasPipelineRunIdValue)
    if (hasPipeline) {
      pipelineBlock.classList.remove("hidden")
    } else {
      pipelineBlock.classList.add("hidden")
    }

    popover.dataset.pipelineAnnotId = this.hasPipelineAnnotIdValue ? String(this.pipelineAnnotIdValue) : ""
    popover.dataset.pipelineRunId = this.hasPipelineRunIdValue ? String(this.pipelineRunIdValue) : ""
    popover.dataset.pipelineUrl = this.hasPipelineUrlValue ? this.pipelineUrlValue : ""
  }

  positionPopover(popover, event) {
    const margin = 8
    popover.style.visibility = "hidden"
    popover.classList.remove("hidden")

    const width = popover.offsetWidth
    const height = popover.offsetHeight
    let left = event.clientX + margin
    let top = event.clientY + margin

    if (left + width > window.innerWidth - margin) {
      left = Math.max(margin, window.innerWidth - width - margin)
    }
    if (top + height > window.innerHeight - margin) {
      top = Math.max(margin, event.clientY - height - margin)
    }

    applyRunParamInfoPosition(popover, left, top)
    popover.style.visibility = "visible"
  }
}
