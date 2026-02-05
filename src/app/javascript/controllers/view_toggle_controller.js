import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["cardView", "listView", "cardBtn", "listBtn"]

  connect() {
    // Load saved preference from localStorage
    const savedView = localStorage.getItem("projectsViewPreference")
    if (savedView === "list") {
      this.showList()
    }
  }

  showCards() {
    this.cardViewTarget.classList.remove("hidden")
    this.listViewTarget.classList.add("hidden")
    
    // Update button styles
    this.cardBtnTarget.classList.add("bg-blue-600", "text-white")
    this.cardBtnTarget.classList.remove("bg-white", "text-gray-600", "hover:bg-gray-50")
    
    this.listBtnTarget.classList.remove("bg-blue-600", "text-white")
    this.listBtnTarget.classList.add("bg-white", "text-gray-600", "hover:bg-gray-50")
    
    // Save preference
    localStorage.setItem("projectsViewPreference", "cards")
  }

  showList() {
    this.cardViewTarget.classList.add("hidden")
    this.listViewTarget.classList.remove("hidden")
    
    // Update button styles
    this.listBtnTarget.classList.add("bg-blue-600", "text-white")
    this.listBtnTarget.classList.remove("bg-white", "text-gray-600", "hover:bg-gray-50")
    
    this.cardBtnTarget.classList.remove("bg-blue-600", "text-white")
    this.cardBtnTarget.classList.add("bg-white", "text-gray-600", "hover:bg-gray-50")
    
    // Save preference
    localStorage.setItem("projectsViewPreference", "list")
  }
}

