// Import and register all your controllers from the importmap under controllers/*
import { Application } from "@hotwired/stimulus"

console.log('Starting Stimulus application...')
const application = Application.start()

// Configure Stimulus development experience
application.debug = true
window.Stimulus   = application

console.log('Stimulus application started:', application)

import DropdownController from "controllers/dropdown_controller"
application.register("dropdown", DropdownController)
console.log('Dropdown controller registered')

// Manually register all controllers since we're not using stimulus-loading
import TestController from "controllers/test_controller"
application.register("test", TestController)
console.log('Test controller registered')

import VisualizationController from "controllers/visualization_controller"
application.register("visualization", VisualizationController)
console.log('Visualization controller registered')

import RangeSliderController from "controllers/range_slider_controller"
application.register("range-slider", RangeSliderController)
console.log('Range slider controller registered')

import NavDropdownController from "controllers/nav_dropdown_controller"
application.register("nav-dropdown", NavDropdownController)
console.log('Nav dropdown controller registered')

import NavItemController from "controllers/nav_item_controller"
application.register("nav-item", NavItemController)
console.log('Nav item controller registered')

import FileUploadController from "controllers/file_upload_controller"
application.register("file-upload", FileUploadController)
console.log('File upload controller registered')

import OrganismSelectorController from "controllers/organism_selector_controller"
application.register("organism-selector", OrganismSelectorController)
console.log('Organism selector controller registered')

// Log all registered controllers
console.log('Registered controllers:', Object.keys(application.router.modulesByIdentifier)) 