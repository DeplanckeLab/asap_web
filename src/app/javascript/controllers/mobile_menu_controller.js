import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "menu"]

  connect() {
    // Close menu when clicking outside
    this.boundCloseMenu = this.closeMenu.bind(this)
    document.addEventListener('click', this.boundCloseMenu, true)
    
    // Close menu on escape key
    this.boundHandleEscape = this.handleEscape.bind(this)
    document.addEventListener('keydown', this.boundHandleEscape)
    
    // Close menu when navigation links are clicked
    const links = this.menuTarget.querySelectorAll('a')
    links.forEach(link => {
      link.addEventListener('click', () => {
        // Small delay to allow navigation to proceed
        setTimeout(() => this.closeMenu(), 100)
      })
    })
  }

  disconnect() {
    if (this.boundCloseMenu) {
      document.removeEventListener('click', this.boundCloseMenu, true)
    }
    if (this.boundHandleEscape) {
      document.removeEventListener('keydown', this.boundHandleEscape)
    }
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const isHidden = this.menuTarget.classList.contains('hidden')
    
    if (isHidden) {
      this.openMenu()
    } else {
      this.closeMenu()
    }
  }

  openMenu() {
    this.menuTarget.classList.remove('hidden')
    this.toggleTarget.setAttribute('aria-expanded', 'true')
  }

  closeMenu(event) {
    // Don't close if clicking on the toggle button or inside the menu
    if (event && event.target && (
      this.toggleTarget.contains(event.target) ||
      this.menuTarget.contains(event.target)
    )) {
      return
    }
    
    this.menuTarget.classList.add('hidden')
    this.toggleTarget.setAttribute('aria-expanded', 'false')
  }

  handleEscape(event) {
    if (event.key === 'Escape' && !this.menuTarget.classList.contains('hidden')) {
      this.closeMenu()
    }
  }
}

