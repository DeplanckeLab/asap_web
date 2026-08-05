import { Controller } from "@hotwired/stimulus"

// Updates the icon select to the type's default when the news type changes,
// but only if the current icon still matches a known type default.
export default class extends Controller {
  static targets = ["type", "icon"]
  static values = {
    defaults: Object
  }

  typeChanged() {
    const nextDefault = this.defaultsValue[this.typeTarget.value]
    if (!nextDefault) return

    const defaultIcons = Object.values(this.defaultsValue)
    if (defaultIcons.includes(this.iconTarget.value) || this.iconTarget.value === "") {
      this.iconTarget.value = nextDefault
    }
  }
}
