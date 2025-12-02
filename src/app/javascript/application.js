import "@hotwired/turbo-rails"
import "controllers"
import "channels"

// Fix menu items styling after Turbo navigation
// This runs globally to ensure menu items have correct white text on black header
function fixMenuItemsStyling() {
  const header = document.querySelector('header')
  if (!header) {
    return
  }

  const allMenuItems = header.querySelectorAll('.menu-item')
  
  allMenuItems.forEach(item => {
    // Remove all problematic dark text classes
    item.classList.remove(
      "bg-gray-100", 
      "text-gray-800", 
      "text-gray-900",
      "text-gray-700",
      "dark:bg-neutral-700", 
      "dark:text-white", 
      "bg-white/20",
      "bg-gray-700"
    )
    
    // For regular menu items (not dropdown), ensure white text
    if (item.classList.contains('menu-item-default') && !item.classList.contains('menu-item-dropdown')) {
      item.classList.add('text-white')
      item.classList.remove("text-gray-800", "text-gray-900", "text-gray-700")
    }
  })
}

// Run on initial load
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', fixMenuItemsStyling)
} else {
  fixMenuItemsStyling()
}

// Run on every Turbo navigation event
document.addEventListener('turbo:load', () => {
  // Use multiple timeouts to catch the DOM at different stages
  setTimeout(fixMenuItemsStyling, 0)
  setTimeout(fixMenuItemsStyling, 50)
  setTimeout(fixMenuItemsStyling, 100)
  setTimeout(fixMenuItemsStyling, 200)
})

document.addEventListener('turbo:render', () => {
  setTimeout(fixMenuItemsStyling, 0)
  setTimeout(fixMenuItemsStyling, 50)
})

document.addEventListener('turbo:before-cache', fixMenuItemsStyling)
