/**
 * Scroll the new-run form body so an attribute block sits at the top of the
 * visible area. Stops at the bottom of the scroll range when there is not
 * enough content below to bring the block fully to the top.
 */
export function scrollFormAttrIntoView(fromElement) {
  if (!fromElement || !fromElement.closest) {
    return
  }

  const attributeBlock = fromElement.closest("[data-attr-name]")
  const scrollContainer = fromElement.closest(".std-form-req-body")
  if (!attributeBlock || !scrollContainer) {
    return
  }

  const containerRect = scrollContainer.getBoundingClientRect()
  const blockRect = attributeBlock.getBoundingClientRect()
  const delta = blockRect.top - containerRect.top
  if (Math.abs(delta) < 1) {
    return
  }

  const maxScroll = Math.max(0, scrollContainer.scrollHeight - scrollContainer.clientHeight)
  const targetScroll = Math.min(Math.max(0, scrollContainer.scrollTop + delta), maxScroll)
  if (Math.abs(targetScroll - scrollContainer.scrollTop) < 1) {
    return
  }

  scrollContainer.scrollTo({ top: targetScroll, behavior: "smooth" })
}
