import { Controller } from "@hotwired/stimulus"
import { showPipelineRunsPanel } from "controllers/pipeline_runs_panel"

const POPOVER_ID = "run-param-info-popover"

let lastAnchorElement = null
let boundOutsideClick = null
let boundEscape = null
let dragHandlersBound = false

function makeRunParamInfoDraggable(popover, handle) {
  if (dragHandlersBound) return
  dragHandlersBound = true

  let isDragging = false
  let startX
  let startY
  let initialLeft
  let initialTop

  handle.addEventListener("mousedown", (event) => {
    if (event.target.closest('button[aria-label="Close"]')) return

    isDragging = true
    startX = event.clientX
    startY = event.clientY

    const rect = popover.getBoundingClientRect()
    initialLeft = rect.left
    initialTop = rect.top

    popover.style.transition = "none"
    handle.style.cursor = "move"
    document.body.style.userSelect = "none"
    event.preventDefault()
  })

  document.addEventListener("mousemove", (event) => {
    if (!isDragging) return

    let newLeft = initialLeft + (event.clientX - startX)
    let newTop = initialTop + (event.clientY - startY)

    const rect = popover.getBoundingClientRect()
    newLeft = Math.max(0, Math.min(newLeft, window.innerWidth - rect.width))
    newTop = Math.max(0, Math.min(newTop, window.innerHeight - rect.height))

    popover.style.left = `${newLeft}px`
    popover.style.top = `${newTop}px`
  })

  document.addEventListener("mouseup", () => {
    if (!isDragging) return
    isDragging = false
    popover.style.transition = ""
    handle.style.cursor = "move"
    document.body.style.userSelect = ""
  })
}

function closeRunParamInfoPopover() {
  const popover = document.getElementById(POPOVER_ID)
  if (!popover) return
  popover.classList.add("hidden")
  popover.dataset.openFor = ""
  unbindRunParamInfoDismissHandlers()
}

function unbindRunParamInfoDismissHandlers() {
  if (boundOutsideClick) {
    document.removeEventListener("click", boundOutsideClick)
    boundOutsideClick = null
  }
  if (boundEscape) {
    document.removeEventListener("keydown", boundEscape)
    boundEscape = null
  }
}

function bindRunParamInfoDismissHandlers() {
  if (boundOutsideClick) return

  boundOutsideClick = (event) => {
    const popover = document.getElementById(POPOVER_ID)
    if (!popover || popover.classList.contains("hidden")) return
    if (popover.contains(event.target)) return
    if (event.target.closest('[data-controller~="run-param-info"]')) return
    closeRunParamInfoPopover()
  }

  boundEscape = (event) => {
    if (event.key === "Escape") closeRunParamInfoPopover()
  }

  document.addEventListener("click", boundOutsideClick)
  document.addEventListener("keydown", boundEscape)
}

function ensureRunParamInfoPopover() {
  let popover = document.getElementById(POPOVER_ID)
  if (popover) return popover

  popover = document.createElement("div")
  popover.id = POPOVER_ID
  popover.className = "hidden fixed z-[60] w-[min(28rem,92vw)] max-h-[min(24rem,70vh)] bg-white rounded-lg border border-gray-200 shadow-xl flex flex-col overflow-hidden"
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
    if (popover.dataset.openFor === this.element.id && !popover.classList.contains("hidden")) {
      closeRunParamInfoPopover()
      return
    }

    this.populatePopover(popover)
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

    popover.style.left = `${left}px`
    popover.style.top = `${top}px`
    popover.style.visibility = "visible"
  }
}
