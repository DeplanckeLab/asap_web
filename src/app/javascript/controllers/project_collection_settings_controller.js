import { Controller } from "@hotwired/stimulus"

// Toggle collection membership fields on project settings.
export default class extends Controller {
  static targets = ["mode", "existingFields", "metadataFields", "collectionSelect", "title", "description"]

  connect() {
    this.syncVisibility()
  }

  onModeChange() {
    this.syncVisibility()
    if (this.modeTarget.value === "new") {
      if (this.hasTitleTarget) this.titleTarget.value = ""
      if (this.hasDescriptionTarget) this.descriptionTarget.value = ""
    } else if (this.modeTarget.value === "existing") {
      this.onCollectionChange()
    }
  }

  onCollectionChange() {
    if (!this.hasCollectionSelectTarget) return
    const option = this.collectionSelectTarget.selectedOptions[0]
    if (!option || !option.value) return
    if (this.hasTitleTarget) this.titleTarget.value = option.dataset.title || ""
    if (this.hasDescriptionTarget) this.descriptionTarget.value = option.dataset.description || ""
  }

  syncVisibility() {
    const mode = this.hasModeTarget ? this.modeTarget.value : "none"
    if (this.hasExistingFieldsTarget) {
      this.existingFieldsTarget.classList.toggle("hidden", mode !== "existing")
    }
    if (this.hasMetadataFieldsTarget) {
      this.metadataFieldsTarget.classList.toggle("hidden", mode === "none")
    }
  }
}
