import { Controller } from "@hotwired/stimulus"
import { installImportMetadataModal, openAddMetadataModal } from "lib/import_metadata_modal"

let installed = false

function ensureImportMetadataModalInstalled() {
  if (installed) return
  installImportMetadataModal()
  installed = true
}

// Opens the shared Import metadata modal from analysis step headers.
// Modal markup is on the analysis page; behavior comes from lib/import_metadata_modal.
export default class extends Controller {
  connect() {
    ensureImportMetadataModalInstalled()
  }

  open(event) {
    event.preventDefault()
    ensureImportMetadataModalInstalled()

    if (typeof openAddMetadataModal !== "function") {
      console.error("[OpenImportMetadata] openAddMetadataModal failed to install")
      return
    }
    openAddMetadataModal()
  }
}
