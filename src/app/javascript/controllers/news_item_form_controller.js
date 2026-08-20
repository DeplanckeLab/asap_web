import { Controller } from "@hotwired/stimulus"

// Updates the icon select to the type's default when the news type changes,
// but only if the current icon still matches a known type default.
// Also keeps "Show on welcome page" enabled only while Published is checked.
export default class extends Controller {
  static targets = ["type", "icon", "published", "showOnWelcome"]
  static values = {
    defaults: Object
  }

  connect() {
    this.syncWelcomeAvailability()
  }

  typeChanged() {
    const nextDefault = this.defaultsValue[this.typeTarget.value]
    if (!nextDefault) return

    const defaultIcons = Object.values(this.defaultsValue)
    if (defaultIcons.includes(this.iconTarget.value) || this.iconTarget.value === "") {
      this.iconTarget.value = nextDefault
    }
  }

  publishedChanged() {
    this.syncWelcomeAvailability()
  }

  syncWelcomeAvailability() {
    if (!this.hasPublishedTarget || !this.hasShowOnWelcomeTarget) return

    const published = this.publishedTarget.checked
    this.showOnWelcomeTarget.disabled = !published
    if (!published) {
      this.showOnWelcomeTarget.checked = false
    }
  }
}
