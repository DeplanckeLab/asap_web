import { Controller } from "@hotwired/stimulus"

console.log('Test controller file loaded')

export default class extends Controller {
  connect() {
    console.log('Test controller connected!')
  }

  testAction() {
    console.log('Test action called!')
    alert('Test controller is working!')
  }
}


