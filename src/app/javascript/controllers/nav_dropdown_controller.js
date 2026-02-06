import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    hiddenClass: { type: String, default: "hidden" }
  }

  connect() {
    this.toggleButton = this.element.querySelector("[data-nav-dropdown-toggle]")
    this.menu = this.element.querySelector("[data-nav-menu]")

    if (!this.toggleButton || !this.menu) return

    this.toggleHandler = this.toggleMenu.bind(this)
    this.outsideClickHandler = this.handleOutsideClick.bind(this)
    this.closeEventHandler = this.closeMenu.bind(this)

    this.toggleButton.addEventListener("click", this.toggleHandler)
    document.addEventListener("click", this.outsideClickHandler)
    this.element.addEventListener("nav-dropdown:close", this.closeEventHandler)
  }

  disconnect() {
    if (!this.toggleButton || !this.menu) return

    this.toggleButton.removeEventListener("click", this.toggleHandler)
    document.removeEventListener("click", this.outsideClickHandler)
    this.element.removeEventListener("nav-dropdown:close", this.closeEventHandler)
  }

  toggleMenu(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.isHidden()) {
      this.closeOtherMenus()
      this.openMenu()
    } else {
      this.closeMenu()
    }
  }

  handleOutsideClick(event) {
    if (!this.element.contains(event.target)) {
      this.closeMenu()
    }
  }

  closeOtherMenus() {
    document.querySelectorAll('[data-controller~="nav-dropdown"]').forEach((dropdown) => {
      if (dropdown === this.element) return
      dropdown.dispatchEvent(new CustomEvent("nav-dropdown:close", { bubbles: false }))
    })
  }

  openMenu() {
    // Reset positioning before showing to get accurate dimensions
    this.menu.style.position = 'fixed'
    this.menu.style.left = '0px'
    this.menu.style.top = '0px'
    this.menu.style.visibility = 'hidden'
    this.menu.classList.remove(this.hiddenClassValue)
    
    // Use requestAnimationFrame to ensure layout is calculated
    requestAnimationFrame(() => {
      this.repositionMenu()
      this.menu.style.visibility = 'visible'
      this.toggleButton.setAttribute("aria-expanded", "true")
    })
  }

  repositionMenu() {
    // Get button and menu positions
    const buttonRect = this.toggleButton.getBoundingClientRect()
    const menuRect = this.menu.getBoundingClientRect()
    const viewportWidth = window.innerWidth
    
    // Calculate desired position (centered below button)
    const buttonCenterX = buttonRect.left + buttonRect.width / 2
    let menuLeft = buttonCenterX - menuRect.width / 2
    
    // Constrain to viewport with 8px padding
    const minLeft = 8
    const maxLeft = viewportWidth - menuRect.width - 8
    
    if (menuLeft < minLeft) {
      menuLeft = minLeft
    } else if (menuLeft > maxLeft) {
      menuLeft = maxLeft
    }
    
    // Position the menu just below the button
    this.menu.style.left = menuLeft + 'px'
    this.menu.style.top = (buttonRect.bottom + 4) + 'px'
  }

  closeMenu() {
    if (this.isHidden()) return
    this.menu.classList.add(this.hiddenClassValue)
    this.toggleButton.setAttribute("aria-expanded", "false")
  }

  isHidden() {
    return this.menu.classList.contains(this.hiddenClassValue)
  }
}

