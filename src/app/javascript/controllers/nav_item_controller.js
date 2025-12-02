import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Set active state when controller connects
    this.setActiveState()
  }

  setActiveState() {
    const currentPath = window.location.pathname
    const itemPath = this.element.getAttribute("href")
    const isDropdownItem = this.element.classList.contains('menu-item-dropdown')
    const isMenuItem = this.element.classList.contains('menu-item')

    // Only modify classes for menu items, not for other elements like buttons or logo
    if (!isMenuItem && !isDropdownItem) {
      // For non-menu items, only set aria-current if path matches
      this.element.removeAttribute("aria-current")
      if (itemPath && (
        itemPath === currentPath || 
        (currentPath === "/" && itemPath === "/")
      )) {
        this.element.setAttribute("aria-current", "page")
      }
      return
    }
    
    // Reset state - only for menu items
    // Remove active state classes
    this.element.classList.remove("bg-gray-100", "text-gray-800", "dark:bg-neutral-700", "dark:text-white", "bg-white/20")
    
    // Different default styling for dropdown items vs regular nav items
    if (isDropdownItem) {
      this.element.classList.add("text-gray-800", "dark:text-neutral-200")
    } else if (isMenuItem) {
      // For regular menu items on black header, ensure white text is maintained
      this.element.classList.remove("text-gray-800", "text-gray-900", "text-gray-700")
      // Explicitly ensure white text for non-active items
      if (!this.element.classList.contains('bg-white/20')) {
        this.element.classList.add('text-white')
      }
    }
    
    this.element.removeAttribute("aria-current")
    
    // Set active state if current path matches
    if (itemPath && (
      itemPath === currentPath || 
      (currentPath === "/" && itemPath === "/")
    )) {
      if (isMenuItem) {
        // For black header, use white text with subtle background
        this.element.classList.remove("text-gray-800", "dark:text-neutral-200")
        this.element.classList.add("bg-white/20", "text-white")
      }
      this.element.setAttribute("aria-current", "page")
    }
  }

  navigate() {
    // Update active state after navigation
    setTimeout(() => {
      this.setActiveState()
    }, 50)
  }
} 