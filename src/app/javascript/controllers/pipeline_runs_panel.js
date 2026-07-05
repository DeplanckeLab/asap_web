let dragHandlersBound = false

export function ensurePipelineRunsCard() {
  let card = document.getElementById("pipeline-runs-card")
  if (card) return card

  card = document.createElement("div")
  card.id = "pipeline-runs-card"
  card.className = "hidden fixed z-50 bg-white rounded-lg shadow-xl border border-gray-200"
  card.style.maxWidth = "600px"
  card.style.maxHeight = "80vh"
  card.style.overflow = "hidden"
  card.style.display = "none"
  card.style.flexDirection = "column"
  card.style.left = "-9999px"
  card.style.top = "-9999px"

  const closeButton = document.createElement("button")
  closeButton.type = "button"
  closeButton.className = "text-gray-400 hover:text-gray-600 transition-colors cursor-pointer"
  closeButton.innerHTML = '<span class="text-xl">&times;</span>'
  closeButton.setAttribute("aria-label", "Close")
  closeButton.addEventListener("click", (event) => {
    event.preventDefault()
    event.stopPropagation()
    hidePipelineRunsPanel()
  })

  const header = document.createElement("div")
  header.className = "flex items-center justify-between px-4 py-3 border-b border-gray-200 bg-gray-50"
  header.style.cursor = "move"
  header.style.userSelect = "none"

  const dragHandle = document.createElement("div")
  dragHandle.className = "flex items-center mr-2 text-gray-400 cursor-move hover:text-gray-600 transition-colors"
  dragHandle.style.flexShrink = "0"
  dragHandle.innerHTML = '<svg width="16" height="16" viewBox="0 0 12 12" fill="currentColor"><circle cx="2" cy="2" r="1"/><circle cx="6" cy="2" r="1"/><circle cx="10" cy="2" r="1"/><circle cx="2" cy="6" r="1"/><circle cx="6" cy="6" r="1"/><circle cx="10" cy="6" r="1"/><circle cx="2" cy="10" r="1"/><circle cx="6" cy="10" r="1"/><circle cx="10" cy="10" r="1"/></svg>'
  dragHandle.title = "Drag to move"
  dragHandle.setAttribute("aria-label", "Drag to move")

  const title = document.createElement("h3")
  title.className = "text-lg font-semibold text-gray-900 flex-1"
  title.textContent = "Pipeline Runs"

  header.appendChild(dragHandle)
  header.appendChild(title)
  header.appendChild(closeButton)

  makePipelineCardDraggable(card, header)

  const contentDiv = document.createElement("div")
  contentDiv.className = "flex-1 overflow-y-auto p-4"
  contentDiv.id = "pipeline-runs-content"
  contentDiv.innerHTML = '<div class="text-center text-gray-500 py-8">Click on an input matrix parameter to view its pipeline runs.</div>'

  card.appendChild(header)
  card.appendChild(contentDiv)
  document.body.appendChild(card)

  if (!window.pipelineRunsClickHandlerAdded) {
    document.addEventListener("click", handlePipelineClickOutside)
    window.pipelineRunsClickHandlerAdded = true
  }

  return card
}

function handlePipelineClickOutside(event) {
  const card = document.getElementById("pipeline-runs-card")
  if (!card) return

  const isClickOnCard = card.contains(event.target)
  const isClickOnPipelineBadge = event.target.closest('[data-controller*="pipeline-runs"]')

  if (!isClickOnCard && !isClickOnPipelineBadge) {
    if (card.style.display !== "none" && !card.classList.contains("hidden")) {
      hidePipelineRunsPanel()
    }
  }
}

export function hidePipelineRunsPanel() {
  const card = document.getElementById("pipeline-runs-card")
  if (!card) return
  card.style.display = "none"
  card.classList.add("hidden")
}

export function showPipelineRunsPanel({ url, annotId, runId, anchorElement }) {
  if (!url || (!annotId && !runId)) return

  const card = ensurePipelineRunsCard()
  const contentDiv = document.getElementById("pipeline-runs-content")
  if (contentDiv) {
    contentDiv.innerHTML = '<div class="text-center text-gray-500 py-8">Loading...</div>'
  }

  const anchor = anchorElement || document.body
  const rect = anchor.getBoundingClientRect()
  const cardWidth = 600
  const cardHeight = Math.min(600, window.innerHeight * 0.8)

  let left = rect.left + 10
  if (left + cardWidth > window.innerWidth - 20) {
    left = Math.max(20, rect.right - cardWidth - 10)
  }

  let top = rect.bottom + 10
  if (top + cardHeight > window.innerHeight - 20) {
    top = Math.max(20, rect.top - cardHeight - 10)
  }

  card.style.left = `${left}px`
  card.style.top = `${top}px`
  card.style.width = `${cardWidth}px`
  card.style.display = "flex"
  card.classList.remove("hidden")

  const fetchUrl = annotId
    ? `${url}?annot_id=${encodeURIComponent(annotId)}`
    : `${url}?run_id=${encodeURIComponent(runId)}`

  fetch(fetchUrl, {
    headers: {
      Accept: "text/html",
      "X-Requested-With": "XMLHttpRequest"
    }
  })
    .then((response) => {
      if (!response.ok) {
        throw new Error(`HTTP error! status: ${response.status}`)
      }
      return response.text()
    })
    .then((html) => {
      if (contentDiv) contentDiv.innerHTML = html
    })
    .catch((error) => {
      console.error("Error fetching pipeline runs:", error)
      if (contentDiv) {
        contentDiv.innerHTML = `
          <div class="text-center text-red-600 py-8">
            <p class="font-semibold">Error loading pipeline runs</p>
            <p class="text-sm mt-2">${error.message}</p>
          </div>
        `
      }
    })
}

function makePipelineCardDraggable(card, handle) {
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

    const rect = card.getBoundingClientRect()
    initialLeft = rect.left
    initialTop = rect.top

    card.style.transition = "none"
    card.style.cursor = "move"
    document.body.style.userSelect = "none"
    event.preventDefault()
  })

  document.addEventListener("mousemove", (event) => {
    if (!isDragging) return

    let newLeft = initialLeft + (event.clientX - startX)
    let newTop = initialTop + (event.clientY - startY)

    const rect = card.getBoundingClientRect()
    newLeft = Math.max(0, Math.min(newLeft, window.innerWidth - rect.width))
    newTop = Math.max(0, Math.min(newTop, window.innerHeight - rect.height))

    card.style.left = `${newLeft}px`
    card.style.top = `${newTop}px`
  })

  document.addEventListener("mouseup", () => {
    if (!isDragging) return
    isDragging = false
    card.style.transition = ""
    card.style.cursor = ""
    document.body.style.userSelect = ""
  })
}
