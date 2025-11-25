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
    this.menu.classList.remove(this.hiddenClassValue)
    this.toggleButton.setAttribute("aria-expanded", "true")
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

