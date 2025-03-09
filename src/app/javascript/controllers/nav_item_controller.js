import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.setActiveState()
  }

  setActiveState() {
    const currentPath = window.location.pathname
    const itemPath = this.element.getAttribute("href")
    const isDropdownItem = this.element.classList.contains('menu-item-dropdown')
    
    // Reset state
    this.element.classList.remove("bg-gray-100", "text-gray-800", "dark:bg-neutral-700", "dark:text-white")
    
    // Different default styling for dropdown items vs regular nav items
    if (isDropdownItem) {
      this.element.classList.add("text-gray-800", "dark:text-neutral-200")
    } else {
      this.element.classList.add("text-white", "dark:text-neutral-200")
    }
    
    this.element.removeAttribute("aria-current")
    
    // Set active state if current path matches
    if (itemPath && (
      itemPath === currentPath || 
      (currentPath === "/" && itemPath === "/")
    )) {
      this.element.classList.remove("text-white", "text-gray-800", "dark:text-neutral-200")
      this.element.classList.add("bg-gray-100", "text-gray-800", "dark:bg-neutral-700", "dark:text-white")
      this.element.setAttribute("aria-current", "page")
    }
  }
  
  navigate() {
    // Update active state after navigation
    setTimeout(() => this.setActiveState(), 50)
  }
} 