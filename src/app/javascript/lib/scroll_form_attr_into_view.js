/**
 * Scroll the new-run form body so an attribute block (and optional expanded
 * dropdown/results panel) stays inside the visible area above the pinned footer.
 *
 * Absolutely positioned menus do not increase scrollHeight, so when a field is
 * near the bottom we temporarily add padding-bottom to make room, then scroll.
 *
 * Prefer pinning the attribute block near the top (room for the menu below).
 * Only nudge further if the open panel still overflows the container bottom.
 */

const PADDING_FLAG = "data-form-dropdown-scroll-padding"

function scrollContainerFor(fromElement) {
  if (!fromElement || !fromElement.closest) {
    return null
  }
  return fromElement.closest(".std-form-req-body")
}

export function clearFormAttrScrollPadding(fromElement) {
  const scrollContainer = scrollContainerFor(fromElement)
  if (!scrollContainer || !scrollContainer.hasAttribute(PADDING_FLAG)) {
    return
  }
  const original = scrollContainer.dataset.formAttrOrigPaddingBottom
  if (original != null && original !== "") {
    scrollContainer.style.paddingBottom = original
  } else {
    scrollContainer.style.paddingBottom = ""
  }
  delete scrollContainer.dataset.formAttrOrigPaddingBottom
  delete scrollContainer.dataset.formAttrBasePaddingBottom
  delete scrollContainer.dataset.formAttrExtraPadding
  scrollContainer.removeAttribute(PADDING_FLAG)
}

function ensureBottomPadding(scrollContainer, extraPx) {
  const needed = Math.ceil(Math.max(0, extraPx))
  if (needed < 1) {
    return
  }

  if (!scrollContainer.hasAttribute(PADDING_FLAG)) {
    scrollContainer.dataset.formAttrOrigPaddingBottom = scrollContainer.style.paddingBottom || ""
    const computed = parseFloat(window.getComputedStyle(scrollContainer).paddingBottom) || 0
    scrollContainer.dataset.formAttrBasePaddingBottom = String(computed)
    scrollContainer.setAttribute(PADDING_FLAG, "1")
  }

  const base = parseFloat(scrollContainer.dataset.formAttrBasePaddingBottom) || 0
  const prevExtra = parseFloat(scrollContainer.dataset.formAttrExtraPadding) || 0
  const nextExtra = Math.max(prevExtra, needed)
  scrollContainer.dataset.formAttrExtraPadding = String(nextExtra)
  scrollContainer.style.paddingBottom = `${base + nextExtra}px`
}

/**
 * @param {Element} fromElement
 * @param {{ revealElement?: Element, margin?: number }} [options]
 */
export function scrollFormAttrIntoView(fromElement, options = {}) {
  if (!fromElement || !fromElement.closest) {
    return
  }

  const attributeBlock = fromElement.closest("[data-attr-name]")
  const scrollContainer = scrollContainerFor(fromElement)
  if (!attributeBlock || !scrollContainer) {
    return
  }

  const margin = Number.isFinite(options.margin) ? options.margin : 8
  const revealElement = options.revealElement && options.revealElement.isConnected
    ? options.revealElement
    : null

  const containerRect = scrollContainer.getBoundingClientRect()
  const blockRect = attributeBlock.getBoundingClientRect()

  // 1) Bring the attribute block to the top of the scroll area when possible.
  let delta = blockRect.top - containerRect.top - margin

  // 2) If an open panel still overflows after that, nudge just enough to clear
  //    the container bottom (do not try to fit a long max-height menu entirely).
  if (revealElement) {
    const revealRect = revealElement.getBoundingClientRect()
    const revealBottomAfter = revealRect.bottom - delta
    const overflowAfter = revealBottomAfter - (containerRect.bottom - margin)
    if (overflowAfter > 0) {
      delta += overflowAfter
    }
  }

  if (Math.abs(delta) < 1) {
    return
  }

  if (delta > 0) {
    const maxScrollBefore = Math.max(0, scrollContainer.scrollHeight - scrollContainer.clientHeight)
    const room = maxScrollBefore - scrollContainer.scrollTop
    if (delta > room) {
      ensureBottomPadding(scrollContainer, delta - room + margin)
    }
  }

  const maxScroll = Math.max(0, scrollContainer.scrollHeight - scrollContainer.clientHeight)
  const targetScroll = Math.min(Math.max(0, scrollContainer.scrollTop + delta), maxScroll)
  if (Math.abs(targetScroll - scrollContainer.scrollTop) < 1) {
    return
  }

  scrollContainer.scrollTo({ top: targetScroll, behavior: "smooth" })
}
