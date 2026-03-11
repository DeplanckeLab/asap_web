import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  submitNow() {
    this.element.submit()
  }
}
