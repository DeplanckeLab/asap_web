import { Controller } from "@hotwired/stimulus"

const POPOVER_ID = "form-attr-info-popover"

let boundOutsideClick = null
let boundEscape = null
let dragHandlersBound = false

function makeFormAttrInfoDraggable(popover, handle) {
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

function closeFormAttrInfoPopover() {
  const popover = document.getElementById(POPOVER_ID)
  if (!popover) return
  popover.classList.add("hidden")
  popover.dataset.openFor = ""
  unbindFormAttrInfoDismissHandlers()
}

function unbindFormAttrInfoDismissHandlers() {
  if (boundOutsideClick) {
    document.removeEventListener("click", boundOutsideClick)
    boundOutsideClick = null
  }
  if (boundEscape) {
    document.removeEventListener("keydown", boundEscape)
    boundEscape = null
  }
}

function bindFormAttrInfoDismissHandlers() {
  if (boundOutsideClick) return

  boundOutsideClick = (event) => {
    const popover = document.getElementById(POPOVER_ID)
    if (!popover || popover.classList.contains("hidden")) return
    if (popover.contains(event.target)) return
    if (event.target.closest('[data-controller~="form-attr-info"]')) return
    closeFormAttrInfoPopover()
  }

  boundEscape = (event) => {
    if (event.key === "Escape") closeFormAttrInfoPopover()
  }

  document.addEventListener("click", boundOutsideClick)
  document.addEventListener("keydown", boundEscape)
}

function ensureFormAttrInfoPopover() {
  let popover = document.getElementById(POPOVER_ID)
  if (popover) return popover

  popover = document.createElement("div")
  popover.id = POPOVER_ID
  popover.className = "hidden fixed z-[60] w-[min(28rem,92vw)] max-h-[min(28rem,70vh)] bg-white rounded-lg border border-gray-200 shadow-xl flex flex-col overflow-hidden"
  popover.setAttribute("role", "dialog")
  popover.setAttribute("aria-modal", "false")

  popover.innerHTML = `
    <div data-form-attr-info-target="header" class="flex items-start justify-between gap-2 px-3 py-2 border-b border-gray-200 bg-gray-50 cursor-move select-none">
      <div class="flex items-start gap-2 min-w-0 flex-1">
        <div class="text-gray-400 mt-0.5 flex-shrink-0" aria-hidden="true">
          <svg width="14" height="14" viewBox="0 0 12 12" fill="currentColor"><circle cx="2" cy="2" r="1"/><circle cx="6" cy="2" r="1"/><circle cx="10" cy="2" r="1"/><circle cx="2" cy="6" r="1"/><circle cx="6" cy="6" r="1"/><circle cx="10" cy="6" r="1"/><circle cx="2" cy="10" r="1"/><circle cx="6" cy="10" r="1"/><circle cx="10" cy="10" r="1"/></svg>
        </div>
        <h4 data-form-attr-info-target="title" class="text-sm font-semibold text-gray-900 pr-2"></h4>
      </div>
      <button type="button" data-form-attr-info-target="closeButton" class="text-gray-400 hover:text-gray-600 leading-none p-1 cursor-pointer flex-shrink-0" aria-label="Close">
        <span class="text-lg">&times;</span>
      </button>
    </div>
    <div class="px-3 py-2 overflow-y-auto text-xs space-y-2">
      <div>
        <div class="font-semibold text-gray-700">Name</div>
        <div data-form-attr-info-target="nameField" class="font-mono text-gray-600 break-all"></div>
      </div>
      <div data-form-attr-info-target="descriptionBlock" class="hidden">
        <div class="font-semibold text-gray-700">Description</div>
        <div data-form-attr-info-target="descriptionField" class="text-gray-600 break-words"></div>
      </div>
      <div data-form-attr-info-target="constraintsBlock" class="hidden">
        <div class="font-semibold text-gray-700">Constraints</div>
        <ul data-form-attr-info-target="constraintsList" class="mt-1 list-disc list-inside text-gray-600 space-y-0.5"></ul>
      </div>
      <div data-form-attr-info-target="detailsBlock" class="hidden">
        <div class="font-semibold text-gray-700">Details</div>
        <ul data-form-attr-info-target="detailsList" class="mt-1 list-disc list-inside text-gray-600 space-y-0.5"></ul>
      </div>
    </div>
  `

  document.body.appendChild(popover)

  const header = popover.querySelector('[data-form-attr-info-target="header"]')
  makeFormAttrInfoDraggable(popover, header)

  popover.querySelector('[data-form-attr-info-target="closeButton"]').addEventListener("click", (event) => {
    event.preventDefault()
    event.stopPropagation()
    closeFormAttrInfoPopover()
  })

  popover.addEventListener("click", (event) => event.stopPropagation())

  return popover
}

function populateList(listElement, items) {
  listElement.replaceChildren()
  items.forEach((item) => {
    const li = document.createElement("li")
    li.textContent = item
    listElement.appendChild(li)
  })
}

export default class extends Controller {
  static values = {
    payload: Object
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    this.assignElementId()
    const popover = ensureFormAttrInfoPopover()
    if (popover.dataset.openFor === this.element.id && !popover.classList.contains("hidden")) {
      closeFormAttrInfoPopover()
      return
    }

    this.populatePopover(popover)
    popover.classList.remove("hidden")
    popover.dataset.openFor = this.element.id
    this.positionPopover(popover, event)
    bindFormAttrInfoDismissHandlers()
  }

  assignElementId() {
    if (!this.element.id) {
      this.element.id = `form-attr-help-${Math.random().toString(36).slice(2, 10)}`
    }
  }

  populatePopover(popover) {
    const payload = this.payloadValue || {}
    const title = popover.querySelector('[data-form-attr-info-target="title"]')
    const nameField = popover.querySelector('[data-form-attr-info-target="nameField"]')
    const descriptionBlock = popover.querySelector('[data-form-attr-info-target="descriptionBlock"]')
    const descriptionField = popover.querySelector('[data-form-attr-info-target="descriptionField"]')
    const constraintsBlock = popover.querySelector('[data-form-attr-info-target="constraintsBlock"]')
    const constraintsList = popover.querySelector('[data-form-attr-info-target="constraintsList"]')
    const detailsBlock = popover.querySelector('[data-form-attr-info-target="detailsBlock"]')
    const detailsList = popover.querySelector('[data-form-attr-info-target="detailsList"]')

    title.textContent = payload.label || payload.name || "Field"
    nameField.textContent = payload.name || "-"

    const description = (payload.description || "").trim()
    if (description) {
      descriptionBlock.classList.remove("hidden")
      descriptionField.innerHTML = description
    } else {
      descriptionBlock.classList.add("hidden")
      descriptionField.innerHTML = ""
    }

    const constraints = Array.isArray(payload.constraints) ? payload.constraints.filter(Boolean) : []
    if (constraints.length > 0) {
      constraintsBlock.classList.remove("hidden")
      populateList(constraintsList, constraints)
    } else {
      constraintsBlock.classList.add("hidden")
      constraintsList.replaceChildren()
    }

    const details = Array.isArray(payload.details) ? payload.details.filter(Boolean) : []
    if (details.length > 0) {
      detailsBlock.classList.remove("hidden")
      populateList(detailsList, details)
    } else {
      detailsBlock.classList.add("hidden")
      detailsList.replaceChildren()
    }
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
