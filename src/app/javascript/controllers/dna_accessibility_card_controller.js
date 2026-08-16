import { Controller } from "@hotwired/stimulus"

// Outer ATAC DNA-accessibility card: shows green "Fixed" when both assets exist.
export default class extends Controller {
  static targets = ["fixedBadge"]

  static values = {
    fragmentsPresent: { type: Boolean, default: false },
    tbiPresent: { type: Boolean, default: false }
  }

  connect() {
    this.updateFixedBadge()
  }

  assetSaved(event) {
    const uploadTypeName = event?.detail?.uploadTypeName
    if (uploadTypeName === "dna_accessibility") {
      this.fragmentsPresentValue = true
    } else if (uploadTypeName === "dna_accessibility_tbi") {
      this.tbiPresentValue = true
    }
    this.updateFixedBadge()
  }

  fragmentsPresentValueChanged() {
    this.updateFixedBadge()
  }

  tbiPresentValueChanged() {
    this.updateFixedBadge()
  }

  updateFixedBadge() {
    if (!this.hasFixedBadgeTarget) return
    const fixed = this.fragmentsPresentValue && this.tbiPresentValue
    this.fixedBadgeTarget.classList.toggle("hidden", !fixed)
  }
}
