import { Controller } from "@hotwired/stimulus"

const STORAGE_KEY = "guidedTourPlayerState"

// Enable trace logs: sessionStorage.setItem("guidedTourDebug", "1") then reload,
// or open any page with ?guided_tour_debug=1

export default class extends Controller {
  static values = {
    indexUrl: String
  }

  gtDebugEnabled() {
    try {
      if (new URLSearchParams(window.location.search).get("guided_tour_debug") === "1") {
        return true
      }
      return window.sessionStorage.getItem("guidedTourDebug") === "1"
    } catch {
      return false
    }
  }

  gtLog(...args) {
    if (this.gtDebugEnabled()) {
      console.log("[guided-tour]", ...args)
    }
  }

  connect() {
    this.overlayBackdropRoot = null
    this.overlayPanelRoot = null
    this.panelDragMove = null
    this.panelDragUp = null
    this.highlightedEl = null
    this.tour = null
    this.stepIndex = 0
    this.autoAdvanceTimer = null
    this.autoAdvanceCountdownInterval = null
    this.pendingTourId = null
    this.tryItBar = null

    this.onTurboLoad = this.handleTurboLoad.bind(this)
    this.onKeydown = this.handleKeydown.bind(this)
    document.addEventListener("turbo:load", this.onTurboLoad)
    document.addEventListener("keydown", this.onKeydown)

    this.gtLog("connect")

    const queryTourId = this.takeQueryParamTourId()
    if (queryTourId !== null) {
      this.startTour(queryTourId)
    } else {
      this.resumeIfNeeded()
    }
  }

  disconnect() {
    this.gtLog("disconnect")
    document.removeEventListener("turbo:load", this.onTurboLoad)
    document.removeEventListener("keydown", this.onKeydown)
    this.clearAutoAdvance()
    this.teardownOverlay()
    this.removeHighlight()
    this.removeTryItBar()
  }

  handleTurboLoad() {
    const queryTourId = this.takeQueryParamTourId()
    if (queryTourId !== null) {
      this.startTour(queryTourId)
      return
    }
    this.resumeIfNeeded()
  }

  handleKeydown(event) {
    if (event.key === "Escape" && this.tourOverlayActive()) {
      event.preventDefault()
      this.endTour()
    }
  }

  takeQueryParamTourId() {
    const params = new URLSearchParams(window.location.search)
    const raw = params.get("guided_tour")
    if (!raw) {
      return null
    }
    const tourId = parseInt(raw, 10)
    if (Number.isNaN(tourId)) {
      return null
    }
    params.delete("guided_tour")
    const next = params.toString()
    const path = window.location.pathname + (next ? `?${next}` : "") + window.location.hash
    window.history.replaceState({}, "", path)
    return tourId
  }

  readState() {
    try {
      const raw = sessionStorage.getItem(STORAGE_KEY)
      if (!raw) {
        return null
      }
      const o = JSON.parse(raw)
      if (o.tourId == null) {
        return null
      }
      return {
        tourId: o.tourId,
        stepIndex: typeof o.stepIndex === "number" ? o.stepIndex : 0,
        tryIt: !!o.tryIt
      }
    } catch {
      return null
    }
  }

  writeState(tourId, stepIndex, tryIt) {
    sessionStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ tourId, stepIndex, tryIt: !!tryIt })
    )
  }

  clearState() {
    sessionStorage.removeItem(STORAGE_KEY)
  }

  resumeIfNeeded() {
    if (this.pendingTourId) {
      this.gtLog("resumeIfNeeded skip: pendingTourId set")
      return
    }
    const state = this.readState()
    if (!state || !state.tourId) {
      this.gtLog("resumeIfNeeded skip: no state or tourId")
      return
    }
    if (this.tourOverlayActive()) {
      this.gtLog("resumeIfNeeded skip: overlay already active")
      return
    }

    if (state.tryIt) {
      this.fetchTour(state.tourId).then((tour) => {
        if (!this.isPlayerConnected()) {
          return
        }
        if (!tour || !tour.steps || !tour.steps.length) {
          this.clearState()
          this.removeTryItBar()
          return
        }
        this.tour = tour
        this.stepIndex = Math.min(Math.max(0, state.stepIndex), tour.steps.length - 1)
        this.showTryItBar()
      }).catch(() => {
        this.clearState()
        this.removeTryItBar()
      })
      return
    }

      this.fetchTour(state.tourId).then((tour) => {
        if (!this.isPlayerConnected()) {
          this.gtLog("resumeIfNeeded fetch done: player not connected, abort")
          return
        }
        if (!tour || !tour.steps || !tour.steps.length) {
          this.gtLog("resumeIfNeeded: tour empty, clearState")
          this.clearState()
          return
      }
      const idx = Math.min(Math.max(0, state.stepIndex), tour.steps.length - 1)
      const step = tour.steps[idx]
      if (!step) {
        this.gtLog("resumeIfNeeded: step missing at index", idx)
        this.clearState()
        return
      }
      const here = window.location.pathname + window.location.search
      if (!this.pathsMatch(step.page_url, here)) {
        this.gtLog("resumeIfNeeded skip: pathsMismatch", {
          stepIndex: idx,
          stepTitle: step.title,
          stepPageUrl: step.page_url,
          location: here
        })
        return
      }
      this.gtLog("resumeIfNeeded: opening step", { idx, title: step.title, here })
      this.tour = tour
      this.stepIndex = idx
      void this.openTourAtCurrentStep({ fromResume: true })
    }).catch((err) => {
      this.gtLog("resumeIfNeeded fetch failed", err)
      this.clearState()
    })
  }

  apiBase() {
    return this.indexUrlValue.replace(/\.json\/?$/i, "").replace(/\/?$/, "")
  }

  tourShowUrl(id) {
    return `${this.apiBase()}/${id}`
  }

  async fetchTour(id) {
    const res = await fetch(this.tourShowUrl(id), {
      headers: { Accept: "application/json" },
      credentials: "same-origin"
    })
    if (!res.ok) {
      throw new Error("Tour fetch failed")
    }
    return res.json()
  }

  startTour(tourId) {
    this.pendingTourId = tourId
    this.clearAutoAdvance()
    this.teardownOverlay()
    this.removeHighlight()
    this.removeTryItBar()
    this.fetchTour(tourId).then((tour) => {
      this.pendingTourId = null
      if (!this.isPlayerConnected()) {
        return
      }
      if (!tour.steps || tour.steps.length === 0) {
        return
      }
      this.tour = tour
      this.stepIndex = 0
      this.writeState(tour.id, 0, false)
      this.goToStep(0)
    }).catch(() => {
      this.pendingTourId = null
    })
  }

  endTour() {
    this.gtLog("endTour")
    this.pendingTourId = null
    this.clearAutoAdvance()
    this.clearState()
    this.tour = null
    this.stepIndex = 0
    this.teardownOverlay()
    this.removeHighlight()
    this.removeTryItBar()
  }

  goToStep(index) {
    if (!this.isPlayerConnected() || !this.tour || !this.tour.steps[index]) {
      this.gtLog("goToStep abort", { index, connected: this.isPlayerConnected(), hasTour: !!this.tour })
      return
    }
    this.stepIndex = index
    this.writeState(this.tour.id, index, false)
    const step = this.tour.steps[index]
    const here = window.location.pathname + window.location.search
    const match = this.pathsMatch(step.page_url, here)
    this.gtLog("goToStep", { index, title: step.title, stepPageUrl: step.page_url, here, pathsMatch: match })
    if (!match) {
      const target = this.normalizeUrl(step.page_url)
      this.teardownOverlay()
      this.removeHighlight()
      this.gtLog("goToStep Turbo.visit", target)
      if (window.Turbo && typeof window.Turbo.visit === "function") {
        window.Turbo.visit(target)
      } else {
        window.location.href = target
      }
      return
    }
    void this.openTourAtCurrentStep({ skipPriorPageReplay: true })
  }

  async replayPriorSamePageStepActions(currentLocation) {
    if (!this.tour?.steps?.length) {
      return
    }
    for (let j = 0; j < this.stepIndex; j += 1) {
      const prior = this.tour.steps[j]
      if (!prior) {
        continue
      }
      if (prior.exclude_from_page_replay === true) {
        continue
      }
      if (!this.pathsMatch(prior.page_url, currentLocation)) {
        continue
      }
      await this.runStepActions(prior.step_actions || [], {
        skipSearchSubmitIfQueryPresent: true
      })
    }
  }

  browseProjectsSearchQueryPresent() {
    try {
      const u = new URL(window.location.href)
      if (u.pathname !== "/projects") {
        return false
      }
      const q = u.searchParams.get("q")
      return q != null && String(q).length > 0
    } catch {
      return false
    }
  }

  isPlayerConnected() {
    return !!(this.element && this.element.isConnected)
  }

  shouldSkipSearchSubmitClick(item, opts) {
    if (!opts?.skipSearchSubmitIfQueryPresent) {
      return false
    }
    const sel = item.selector != null ? String(item.selector) : ""
    if (!sel.includes("projects-search-submit")) {
      return false
    }
    return this.browseProjectsSearchQueryPresent()
  }

  async openTourAtCurrentStep(options = {}) {
    if (!this.isPlayerConnected()) {
      this.gtLog("openTourAtCurrentStep abort: not connected")
      return
    }
    const step = this.tour.steps[this.stepIndex]
    if (!step) {
      this.gtLog("openTourAtCurrentStep abort: no step", this.stepIndex)
      return
    }
    this.gtLog("openTourAtCurrentStep start", {
      stepIndex: this.stepIndex,
      title: step.title,
      options,
      location: window.location.pathname + window.location.search
    })
    const here = window.location.pathname + window.location.search
    if (options.skipPriorPageReplay !== true) {
      this.gtLog("replayPriorSamePageStepActions", { here })
      await this.replayPriorSamePageStepActions(here)
    }
    if (!this.isPlayerConnected()) {
      this.gtLog("openTourAtCurrentStep abort after replay: not connected")
      return
    }
    const fromResume = options.fromResume === true
    await this.runStepActions(step.step_actions || [], {
      skipSearchSubmitIfQueryPresent: fromResume
    })
    if (!this.isPlayerConnected()) {
      this.gtLog("openTourAtCurrentStep abort after actions: not connected")
      return
    }
    this.removeHighlight()
    const el = this.queryFocusElement(step.focus_element)
    if (el) {
      el.classList.add("guided-tour-target")
      this.highlightedEl = el
      el.scrollIntoView({ block: "center", behavior: "smooth" })
    }
    this.gtLog("openTourAtCurrentStep render panel", { focusFound: !!el, focus: step.focus_element })
    this.renderStepPanel(step, !!el)
    this.scheduleAutoAdvance()
  }

  elementVisibleForTour(el) {
    if (!el || !el.isConnected || !(el instanceof Element)) {
      return false
    }
    let n = el
    while (n) {
      const s = window.getComputedStyle(n)
      if (s.display === "none" || s.visibility === "hidden") {
        return false
      }
      n = n.parentElement
    }
    return true
  }

  queryFocusElement(selector) {
    try {
      const list = document.querySelectorAll(selector)
      let fallback = null
      for (const el of list) {
        if (fallback === null) {
          fallback = el
        }
        if (this.elementVisibleForTour(el)) {
          return el
        }
      }
      return fallback
    } catch {
      return null
    }
  }

  normalizeUrl(pageUrl) {
    if (pageUrl.startsWith("http://") || pageUrl.startsWith("https://")) {
      return pageUrl
    }
    return pageUrl.startsWith("/") ? pageUrl : `/${pageUrl}`
  }

  pathsMatch(expectedRaw, actualRaw) {
    const expected = this.normalizeUrl(expectedRaw)
    const actual = actualRaw.startsWith("/") ? actualRaw : `/${actualRaw}`
    try {
      const exp = new URL(expected, window.location.origin)
      const act = new URL(actual, window.location.origin)
      if (exp.pathname !== act.pathname) {
        return false
      }
      if (!exp.search) {
        return true
      }
      return exp.search === act.search
    } catch {
      return expected === actual
    }
  }

  /**
   * Navigate with Turbo (or full load) and wait until the page has settled.
   * Used for project tabs where the header link may be missing (e.g. embedding detection mismatch).
   */
  visitPath(pathRaw) {
    const path = this.normalizeUrl(pathRaw)
    let targetUrl
    try {
      targetUrl = new URL(path, window.location.origin)
    } catch {
      return Promise.resolve()
    }
    const here = new URL(window.location.href)
    if (targetUrl.pathname === here.pathname && targetUrl.search === here.search) {
      return Promise.resolve()
    }
    return new Promise((resolve) => {
      const timeoutMs = 25000
      let settled = false
      const done = () => {
        if (settled) {
          return
        }
        settled = true
        window.clearTimeout(tid)
        document.removeEventListener("turbo:load", onTurboLoad)
        window.removeEventListener("load", onWinLoad)
        resolve()
      }
      const onTurboLoad = () => done()
      const onWinLoad = () => done()
      document.addEventListener("turbo:load", onTurboLoad)
      window.addEventListener("load", onWinLoad, { once: true })
      const tid = window.setTimeout(done, timeoutMs)
      if (window.Turbo && typeof window.Turbo.visit === "function") {
        window.Turbo.visit(path)
      } else {
        window.location.assign(path)
      }
    })
  }

  async runStepActions(actions, opts = {}) {
    if (!Array.isArray(actions)) {
      return
    }
    for (const item of actions) {
      if (!item || typeof item !== "object") {
        continue
      }
      const action = item.action
      if (action === "wait_for_selector") {
        const timeout = typeof item.timeout_ms === "number" && item.timeout_ms > 0 ? item.timeout_ms : 8000
        await this.waitForSelector(item.selector, timeout)
      } else if (action === "scroll_to") {
        const el = this.queryFocusElement(item.selector)
        if (el) {
          el.scrollIntoView({ block: "center", behavior: "smooth" })
        }
      } else if (action === "click") {
        if (this.shouldSkipSearchSubmitClick(item, opts)) {
          continue
        }
        const el = this.queryFocusElement(item.selector)
        if (el) {
          if (item.skip_if_selector && this.queryFocusElement(item.skip_if_selector)) {
            continue
          }
          el.click()
        }
      } else if (action === "visit") {
        if (item.skip_if_selector && this.queryFocusElement(item.skip_if_selector)) {
          continue
        }
        const p = item.path != null ? String(item.path) : ""
        if (p) {
          await this.visitPath(p)
        }
      } else if (action === "fill") {
        if (item.skip_if_selector && this.queryFocusElement(item.skip_if_selector)) {
          continue
        }
        const el = this.queryFocusElement(item.selector)
        if (el && "value" in el) {
          const v = item.value != null ? String(item.value) : ""
          el.value = v
          el.dispatchEvent(new Event("input", { bubbles: true }))
          el.dispatchEvent(new Event("change", { bubbles: true }))
        }
      }
    }
  }

  waitForSelector(selector, timeoutMs) {
    return new Promise((resolve) => {
      const start = Date.now()
      const tick = () => {
        if (this.queryFocusElement(selector)) {
          resolve()
          return
        }
        if (Date.now() - start >= timeoutMs) {
          resolve()
          return
        }
        window.requestAnimationFrame(tick)
      }
      tick()
    })
  }

  resumeFromTryIt() {
    if (!this.tour) {
      const state = this.readState()
      if (!state || !state.tourId) {
        return
      }
      this.fetchTour(state.tourId).then((tour) => {
        if (!this.isPlayerConnected()) {
          return
        }
        if (!tour || !tour.steps || !tour.steps.length) {
          this.clearState()
          this.removeTryItBar()
          return
        }
        this.tour = tour
        this.stepIndex = Math.min(Math.max(0, state.stepIndex), tour.steps.length - 1)
        this.writeState(this.tour.id, this.stepIndex, false)
        this.removeTryItBar()
        void this.openTourAtCurrentStep({ fromResume: true })
      }).catch(() => {
        this.clearState()
        this.removeTryItBar()
      })
      return
    }
    this.writeState(this.tour.id, this.stepIndex, false)
    this.removeTryItBar()
    void this.openTourAtCurrentStep({ fromResume: true })
  }

  showTryItBar() {
    this.removeTryItBar()
    const bar = document.createElement("div")
    bar.className = "guided-tour-try-bar"
    bar.setAttribute("role", "toolbar")
    bar.setAttribute("aria-label", "Guided tour paused")

    const resume = document.createElement("button")
    resume.type = "button"
    resume.className = "guided-tour-try-bar-btn guided-tour-try-bar-btn-primary"
    resume.textContent = "Resume guided tour"
    resume.addEventListener("click", () => this.resumeFromTryIt())

    const exit = document.createElement("button")
    exit.type = "button"
    exit.className = "guided-tour-try-bar-btn guided-tour-try-bar-btn-secondary"
    exit.textContent = "Exit guided tour"
    exit.addEventListener("click", () => this.endTour())

    bar.appendChild(resume)
    bar.appendChild(exit)
    document.body.appendChild(bar)
    this.tryItBar = bar
  }

  removeTryItBar() {
    if (this.tryItBar && this.tryItBar.parentNode) {
      this.tryItBar.parentNode.removeChild(this.tryItBar)
    }
    this.tryItBar = null
  }

  tourOverlayActive() {
    return !!(this.overlayBackdropRoot || this.overlayPanelRoot)
  }

  /**
   * Epilogue after the last real step: not part of tour.steps, no "Step N of M" line.
   */
  showTourCompleteScreen() {
    if (!this.isPlayerConnected() || !this.tour) {
      return
    }
    this.gtLog("showTourCompleteScreen")
    this.clearAutoAdvance()
    this.removeHighlight()
    this.teardownOverlay()
    this.renderTourCompletePanel()
  }

  renderTourCompletePanel() {
    if (!this.isPlayerConnected()) {
      return
    }
    const backdropWrap = document.createElement("div")
    backdropWrap.className = "guided-tour-overlay"

    const backdrop = document.createElement("div")
    backdrop.className = "guided-tour-backdrop"

    const panel = document.createElement("div")
    panel.className = "guided-tour-panel guided-tour-panel-complete"
    panel.setAttribute("role", "dialog")
    panel.setAttribute("aria-modal", "true")
    panel.setAttribute("aria-labelledby", "guided-tour-complete-title")

    const header = document.createElement("div")
    header.className = "guided-tour-panel-header"
    header.title = "Drag to move"

    const grip = document.createElement("i")
    grip.className = "guided-tour-panel-drag-handle fas fa-grip-vertical"
    grip.setAttribute("aria-hidden", "true")

    const title = document.createElement("h2")
    title.id = "guided-tour-complete-title"
    title.className =
      "guided-tour-panel-title guided-tour-panel-title-in-header guided-tour-complete-title"
    title.textContent = "The end"

    header.appendChild(grip)
    header.appendChild(title)

    const body = document.createElement("div")
    body.className = "guided-tour-panel-body"
    const p = document.createElement("p")
    p.textContent = "You have reached the end of this guided tour."
    body.appendChild(p)

    const meta = document.createElement("div")
    meta.className = "guided-tour-panel-meta guided-tour-panel-meta-complete"
    meta.textContent = "Guided tour complete"

    const actions = document.createElement("div")
    actions.className = "guided-tour-panel-actions"

    const back = document.createElement("button")
    back.type = "button"
    back.className = "guided-tour-btn guided-tour-btn-secondary"
    back.textContent = "Back"
    back.addEventListener("click", () => {
      this.clearAutoAdvance()
      this.goToStep(this.tour.steps.length - 1)
    })

    const close = document.createElement("button")
    close.type = "button"
    close.className = "guided-tour-btn guided-tour-btn-primary"
    close.textContent = "Close"
    close.addEventListener("click", () => this.endTour())

    actions.appendChild(back)
    actions.appendChild(close)

    const footer = document.createElement("div")
    footer.className = "guided-tour-panel-footer"
    footer.appendChild(actions)

    panel.appendChild(header)
    panel.appendChild(body)
    panel.appendChild(meta)
    panel.appendChild(footer)

    backdropWrap.appendChild(backdrop)
    document.body.appendChild(backdropWrap)
    document.body.appendChild(panel)
    this.overlayBackdropRoot = backdropWrap
    this.overlayPanelRoot = panel
    this.attachPanelDrag(panel, header)
  }

  renderStepPanel(step, targetFound) {
    if (!this.isPlayerConnected()) {
      return
    }
    this.teardownOverlay()
    const backdropWrap = document.createElement("div")
    backdropWrap.className = "guided-tour-overlay"

    const backdrop = document.createElement("div")
    backdrop.className = "guided-tour-backdrop"

    const panel = document.createElement("div")
    panel.className = "guided-tour-panel"
    panel.setAttribute("role", "dialog")
    panel.setAttribute("aria-modal", "true")
    panel.setAttribute("aria-labelledby", "guided-tour-step-title")

    const header = document.createElement("div")
    header.className = "guided-tour-panel-header"
    header.title = "Drag to move"

    const grip = document.createElement("i")
    grip.className = "guided-tour-panel-drag-handle fas fa-grip-vertical"
    grip.setAttribute("aria-hidden", "true")

    const title = document.createElement("h2")
    title.id = "guided-tour-step-title"
    title.className = "guided-tour-panel-title guided-tour-panel-title-in-header"
    title.textContent = step.title

    header.appendChild(grip)
    header.appendChild(title)

    const body = document.createElement("div")
    body.className = "guided-tour-panel-body"
    if (step.description) {
      body.innerHTML = step.description
    } else {
      body.textContent = ""
    }

    const meta = document.createElement("div")
    meta.className = "guided-tour-panel-meta"
    meta.textContent = `Step ${this.stepIndex + 1} of ${this.tour.steps.length}`

    const countdown = document.createElement("div")
    countdown.className = "guided-tour-panel-countdown"
    countdown.setAttribute("role", "status")
    countdown.setAttribute("aria-live", "polite")
    countdown.hidden = true

    const countdownLabel = document.createElement("span")
    countdownLabel.className = "guided-tour-countdown-label"
    countdownLabel.textContent = "Next step in"

    const svgNS = "http://www.w3.org/2000/svg"
    const countdownSvg = document.createElementNS(svgNS, "svg")
    countdownSvg.setAttribute("viewBox", "0 0 40 40")
    countdownSvg.setAttribute("class", "guided-tour-countdown-svg")
    countdownSvg.setAttribute("aria-hidden", "true")

    const ringR = 16
    const ringC = 2 * Math.PI * ringR
    const ringCx = 20
    const ringCy = 20

    const trackCircle = document.createElementNS(svgNS, "circle")
    trackCircle.setAttribute("cx", String(ringCx))
    trackCircle.setAttribute("cy", String(ringCy))
    trackCircle.setAttribute("r", String(ringR))
    trackCircle.setAttribute("class", "guided-tour-countdown-track")

    const barCircle = document.createElementNS(svgNS, "circle")
    barCircle.setAttribute("cx", String(ringCx))
    barCircle.setAttribute("cy", String(ringCy))
    barCircle.setAttribute("r", String(ringR))
    barCircle.setAttribute("class", "guided-tour-countdown-bar")
    barCircle.setAttribute("transform", `rotate(-90 ${ringCx} ${ringCy})`)
    barCircle.setAttribute("stroke-dasharray", String(ringC))
    barCircle.setAttribute("stroke-dashoffset", "0")

    countdownSvg.appendChild(trackCircle)
    countdownSvg.appendChild(barCircle)

    const ringWrap = document.createElement("div")
    ringWrap.className = "guided-tour-countdown-ring-wrap"
    ringWrap.appendChild(countdownSvg)

    const countdownValue = document.createElement("span")
    countdownValue.className = "guided-tour-countdown-value"
    countdownValue.setAttribute("aria-hidden", "true")
    ringWrap.appendChild(countdownValue)

    countdown.appendChild(countdownLabel)
    countdown.appendChild(ringWrap)

    const actions = document.createElement("div")
    actions.className = "guided-tour-panel-actions"

    const prev = document.createElement("button")
    prev.type = "button"
    prev.className = "guided-tour-btn guided-tour-btn-secondary"
    prev.textContent = "Back"
    prev.disabled = this.stepIndex === 0
    prev.addEventListener("click", () => {
      this.clearAutoAdvance()
      this.goToStep(this.stepIndex - 1)
    })

    const next = document.createElement("button")
    next.type = "button"
    next.className = "guided-tour-btn guided-tour-btn-primary"
    if (this.stepIndex >= this.tour.steps.length - 1) {
      next.textContent = "Finish"
      next.addEventListener("click", () => this.showTourCompleteScreen())
    } else {
      next.textContent = "Next"
      next.addEventListener("click", () => {
        this.clearAutoAdvance()
        this.goToStep(this.stepIndex + 1)
      })
    }

    const end = document.createElement("button")
    end.type = "button"
    end.className = "guided-tour-btn guided-tour-btn-secondary"
    end.textContent = "Exit tour"
    end.addEventListener("click", () => this.endTour())

    actions.appendChild(prev)
    actions.appendChild(next)
    actions.appendChild(end)

    panel.appendChild(header)
    if (!targetFound) {
      const warn = document.createElement("p")
      warn.className = "guided-tour-panel-warn"
      warn.textContent = "The highlighted area could not be found on this page. You can still follow the text below."
      panel.appendChild(warn)
    }
    panel.appendChild(body)
    panel.appendChild(meta)

    const footer = document.createElement("div")
    footer.className = "guided-tour-panel-footer"
    footer.appendChild(countdown)
    footer.appendChild(actions)
    panel.appendChild(footer)

    backdropWrap.appendChild(backdrop)
    document.body.appendChild(backdropWrap)
    document.body.appendChild(panel)
    this.overlayBackdropRoot = backdropWrap
    this.overlayPanelRoot = panel
    this.attachPanelDrag(panel, header)
  }

  scheduleAutoAdvance() {
    this.clearAutoAdvance()
    if (!this.tour || !this.tour.duration_time || this.tour.duration_time <= 0) {
      return
    }
    if (!this.tour.steps || this.tour.steps.length === 0) {
      return
    }
    const ms = Math.round((this.tour.duration_time * 1000) / this.tour.steps.length)
    const delay = Math.max(ms, 3000)
    const countdownEl = this.overlayPanelRoot?.querySelector(".guided-tour-panel-countdown")
    const barEl = countdownEl?.querySelector(".guided-tour-countdown-bar")
    const valueEl = countdownEl?.querySelector(".guided-tour-countdown-value")
    if (countdownEl && barEl && valueEl) {
      countdownEl.hidden = false
      const endAt = Date.now() + delay
      const circumference = parseFloat(barEl.getAttribute("stroke-dasharray")) || 100.53
      const tick = () => {
        if (!this.tour || !countdownEl.isConnected) {
          this.stopAutoAdvanceCountdown()
          return
        }
        const remainingMs = Math.max(0, endAt - Date.now())
        const ratio = delay > 0 ? remainingMs / delay : 0
        barEl.style.strokeDashoffset = String(circumference * (1 - ratio))
        const sec = Math.ceil(remainingMs / 1000)
        valueEl.textContent = sec > 0 ? String(sec) : "0"
        countdownEl.setAttribute(
          "aria-label",
          sec > 0 ? `Next step in ${sec} seconds` : "Next step"
        )
      }
      tick()
      this.autoAdvanceCountdownInterval = window.setInterval(tick, 250)
    }
    this.autoAdvanceTimer = window.setTimeout(() => {
      this.autoAdvanceTimer = null
      this.stopAutoAdvanceCountdown()
      if (!this.isPlayerConnected() || !this.tour) {
        return
      }
      if (this.stepIndex >= this.tour.steps.length - 1) {
        this.showTourCompleteScreen()
      } else {
        this.goToStep(this.stepIndex + 1)
      }
    }, delay)
  }

  stopAutoAdvanceCountdown() {
    if (this.autoAdvanceCountdownInterval) {
      window.clearInterval(this.autoAdvanceCountdownInterval)
      this.autoAdvanceCountdownInterval = null
    }
    const el = this.overlayPanelRoot?.querySelector(".guided-tour-panel-countdown")
    if (el) {
      el.hidden = true
      el.removeAttribute("aria-label")
      const bar = el.querySelector(".guided-tour-countdown-bar")
      if (bar) {
        bar.style.strokeDashoffset = "0"
      }
      const val = el.querySelector(".guided-tour-countdown-value")
      if (val) {
        val.textContent = ""
      }
    }
  }

  clearAutoAdvance() {
    if (this.autoAdvanceTimer) {
      window.clearTimeout(this.autoAdvanceTimer)
      this.autoAdvanceTimer = null
    }
    this.stopAutoAdvanceCountdown()
  }

  detachPanelDrag() {
    if (this.panelDragMove) {
      document.removeEventListener("mousemove", this.panelDragMove)
      this.panelDragMove = null
    }
    if (this.panelDragUp) {
      document.removeEventListener("mouseup", this.panelDragUp)
      this.panelDragUp = null
    }
  }

  attachPanelDrag(panel, handle) {
    this.detachPanelDrag()
    const onMove = (e) => {
      if (!this.panelDragState) {
        return
      }
      const { startX, startY, origLeft, origTop } = this.panelDragState
      let nx = origLeft + (e.clientX - startX)
      let ny = origTop + (e.clientY - startY)
      const maxX = window.innerWidth - panel.offsetWidth
      const maxY = window.innerHeight - 40
      nx = Math.max(0, Math.min(nx, maxX))
      ny = Math.max(0, Math.min(ny, maxY))
      panel.style.left = `${nx}px`
      panel.style.top = `${ny}px`
    }
    const onUp = () => {
      this.panelDragState = null
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      this.panelDragMove = null
      this.panelDragUp = null
    }
    this.panelDragMove = onMove
    this.panelDragUp = onUp
    handle.addEventListener("mousedown", (e) => {
      if (e.button !== 0) {
        return
      }
      if (e.target.closest && e.target.closest("button, a[href], input, select, textarea")) {
        return
      }
      e.preventDefault()
      const rect = panel.getBoundingClientRect()
      if (!panel.dataset.guidedTourDragInit) {
        panel.style.left = `${rect.left}px`
        panel.style.top = `${rect.top}px`
        panel.style.bottom = "auto"
        panel.style.right = "auto"
        panel.style.transform = "none"
        panel.style.width = `${rect.width}px`
        panel.dataset.guidedTourDragInit = "1"
      }
      const r = panel.getBoundingClientRect()
      this.panelDragState = {
        startX: e.clientX,
        startY: e.clientY,
        origLeft: r.left,
        origTop: r.top
      }
      document.addEventListener("mousemove", onMove)
      document.addEventListener("mouseup", onUp)
    })
  }

  teardownOverlay() {
    this.clearAutoAdvance()
    this.detachPanelDrag()
    this.panelDragState = null
    if (this.overlayBackdropRoot && this.overlayBackdropRoot.parentNode) {
      this.overlayBackdropRoot.parentNode.removeChild(this.overlayBackdropRoot)
    }
    if (this.overlayPanelRoot && this.overlayPanelRoot.parentNode) {
      this.overlayPanelRoot.parentNode.removeChild(this.overlayPanelRoot)
    }
    this.overlayBackdropRoot = null
    this.overlayPanelRoot = null
  }

  removeHighlight() {
    if (this.highlightedEl) {
      this.highlightedEl.classList.remove("guided-tour-target")
    }
    this.highlightedEl = null
  }
}
