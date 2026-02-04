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

import ProjectCreationController from "controllers/project_creation_controller"
application.register("project-creation", ProjectCreationController)
console.log('Project creation controller registered')

import ParsingStatusController from "controllers/parsing_status_controller"
application.register("parsing-status", ParsingStatusController)
console.log('Parsing status controller registered')

import StepSelectorController from "controllers/step_selector_controller"
application.register("step-selector", StepSelectorController)
console.log('Step selector controller registered')

import RestartStepController from "controllers/restart_step_controller"
application.register("restart-step", RestartStepController)
console.log('Restart step controller registered')

import ParsingTimerController from "controllers/parsing_timer_controller"
application.register("parsing-timer", ParsingTimerController)
console.log('Parsing timer controller registered')

import QueuePositionController from "controllers/queue_position_controller"
application.register("queue-position", QueuePositionController)
console.log('Queue position controller registered')

import CellFilteringController from "controllers/cell_filtering_controller"
application.register("cell-filtering", CellFilteringController)
console.log('Cell filtering controller registered')

import FormReqController from "controllers/form_req_controller"
application.register("form-req", FormReqController)
console.log('Form req controller registered')

import SlideInFormController from "controllers/slide_in_form_controller"
application.register("slide-in-form", SlideInFormController)
console.log('Slide in form controller registered')

import DeleteRunController from "controllers/delete_run_controller"
application.register("delete-run", DeleteRunController)
console.log('Delete run controller registered')

import DeleteAllRunsController from "controllers/delete_all_runs_controller"
application.register("delete-all-runs", DeleteAllRunsController)
console.log('Delete all runs controller registered')

import InputDataSelectorController from "controllers/input_data_selector_controller"
application.register("input-data-selector", InputDataSelectorController)
console.log('Input data selector controller registered')

import RunTimerController from "controllers/run_timer_controller"
application.register("run-timer", RunTimerController)
console.log('Run timer controller registered')

import RunParamsToggleController from "controllers/run_params_toggle_controller"
application.register("run-params-toggle", RunParamsToggleController)
console.log('Run params toggle controller registered')

import MobileMenuController from "controllers/mobile_menu_controller"
application.register("mobile-menu", MobileMenuController)
console.log('Mobile menu controller registered')

import DataViewController from "controllers/data_view_controller"
application.register("data-view", DataViewController)
console.log('Data view controller registered')

import PipelineRunsController from "controllers/pipeline_runs_controller"
application.register("pipeline-runs", PipelineRunsController)
console.log('Pipeline runs controller registered')

import RunSelectionController from "controllers/run_selection_controller"
application.register("run-selection", RunSelectionController)
console.log('Run selection controller registered')

import HeaderRunStatusController from "controllers/header_run_status_controller"
application.register("header-run-status", HeaderRunStatusController)
console.log('Header run status controller registered')

// Log all registered controllers
console.log('Registered controllers:', Object.keys(application.router.modulesByIdentifier))

// Manually scan for controllers after a short delay to ensure DOM is ready
// This helps with controllers that are rendered server-side but might not be found immediately
if (typeof document !== 'undefined') {
  function checkAndConnectStepSelector() {
    console.log('[ManualScan] Checking for step-selector element...')
    const stepSelectorElement = document.querySelector('[data-controller*="step-selector"]')
    if (stepSelectorElement) {
      console.log('[ManualScan] Found step-selector element:', stepSelectorElement)
      console.log('[ManualScan] Element data-controller:', stepSelectorElement.getAttribute('data-controller'))
      // Check if Stimulus has connected to this element
      try {
        const controller = application.getControllerForElementAndIdentifier(stepSelectorElement, 'step-selector')
        if (!controller) {
          console.warn('[ManualScan] Controller NOT connected! Element exists but Stimulus didn\'t connect.')
          console.log('[ManualScan] Trying to manually trigger connection...')
          // Try to manually dispatch a DOMContentLoaded event or trigger Stimulus scan
          const event = new Event('DOMContentLoaded', { bubbles: true })
          document.dispatchEvent(event)
        } else {
          console.log('[ManualScan] Controller already connected:', controller)
          // Check if connect() was called
          if (!controller.currentStepId && !controller._connected) {
            console.warn('[ManualScan] Controller exists but connect() wasn\'t called! Manually calling connect()...')
            try {
              controller.connect()
            } catch (e) {
              console.error('[ManualScan] Error manually calling connect():', e)
            }
          } else {
            console.log('[ManualScan] Controller appears to be properly connected, currentStepId:', controller.currentStepId)
            // Even if connected, check if we need to load step results
            const urlParams = new URLSearchParams(window.location.search)
            const stepIdFromUrl = urlParams.get('step_id')
            const runIdFromUrl = urlParams.get('run_id')
            console.log('[ManualScan] URL step_id:', stepIdFromUrl, 'run_id:', runIdFromUrl, 'Controller currentStepId:', controller.currentStepId)
            
            // If run_id is present, don't load step results - the run panel will be loaded by step_selector_controller
            if (runIdFromUrl) {
              console.log('[ManualScan] run_id found in URL, skipping step results load - run panel will be loaded by step_selector_controller')
              return
            }
            
            // Check if content target exists and is empty or hidden
            let contentTarget
            try {
              contentTarget = controller.contentTarget
            } catch (e) {
              console.warn('[ManualScan] Could not access contentTarget:', e)
              contentTarget = null
            }
            const isEmpty = !contentTarget || !contentTarget.innerHTML || contentTarget.innerHTML.trim().length === 0
            let isHidden = false
            if (contentTarget) {
              const displayStyle = window.getComputedStyle(contentTarget).display
              isHidden = displayStyle === 'none'
              console.log('[ManualScan] Content target:', contentTarget)
              console.log('[ManualScan] Content target empty?', isEmpty)
              console.log('[ManualScan] Content HTML length:', contentTarget.innerHTML ? contentTarget.innerHTML.length : 0)
              console.log('[ManualScan] Content display style:', displayStyle, '(hidden:', isHidden, ')')
            } else {
              console.log('[ManualScan] Content target is null')
            }
            
            // If content is hidden, always reload to show it (unless we're loading a run panel)
            if (isHidden && controller.currentStepId && !runIdFromUrl) {
              console.log('[ManualScan] Content is hidden, forcing reload for current step:', controller.currentStepId)
              const stepElement = stepSelectorElement.querySelector(`[data-step-id="${controller.currentStepId}"]`)
              if (stepElement && typeof controller.loadStepResults === 'function') {
                controller.loadStepResults(controller.currentStepId, stepElement, true)
              }
            } else if (stepIdFromUrl && !runIdFromUrl) {
              // Always reload if step_id is in URL (after restart, content should be refreshed)
              // Also reload if content is hidden (display: none)
              const shouldReload = !controller.currentStepId || controller.currentStepId !== stepIdFromUrl || isEmpty || isHidden
              console.log('[ManualScan] Should reload?', shouldReload, '(currentStepId:', controller.currentStepId, 'stepIdFromUrl:', stepIdFromUrl, 'isEmpty:', isEmpty, 'isHidden:', isHidden, ')')
              if (shouldReload) {
                console.log('[ManualScan] Loading step results for step_id:', stepIdFromUrl)
                const stepElement = stepSelectorElement.querySelector(`[data-step-id="${stepIdFromUrl}"]`)
                console.log('[ManualScan] Step element found:', stepElement)
                if (stepElement && typeof controller.loadStepResults === 'function') {
                  controller.currentStepId = stepIdFromUrl
                  controller.element.setAttribute('data-current-step-id', stepIdFromUrl)
                  controller.loadStepResults(stepIdFromUrl, stepElement, true)
                } else if (!stepElement) {
                  console.warn('[ManualScan] Step element not found, refreshing steps panel first...')
                  controller.refreshStepsPanel()
                  setTimeout(function() {
                    const stepElement2 = stepSelectorElement.querySelector(`[data-step-id="${stepIdFromUrl}"]`)
                    if (stepElement2 && typeof controller.loadStepResults === 'function') {
                      controller.currentStepId = stepIdFromUrl
                      controller.element.setAttribute('data-current-step-id', stepIdFromUrl)
                      controller.loadStepResults(stepIdFromUrl, stepElement2, true)
                    } else {
                      console.error('[ManualScan] Step element still not found after refresh')
                    }
                  }, 500)
                }
              }
            } else if (isEmpty && controller.currentStepId && !runIdFromUrl) {
              // No step_id in URL but content is empty - try to reload current step (unless we're loading a run panel)
              console.log('[ManualScan] No step_id in URL but content empty, reloading current step...')
              const stepElement = stepSelectorElement.querySelector(`[data-step-id="${controller.currentStepId}"]`)
              if (stepElement && typeof controller.loadStepResults === 'function') {
                controller.loadStepResults(controller.currentStepId, stepElement, true)
              }
            }
          }
        }
      } catch (e) {
        console.error('[ManualScan] Error checking controller:', e)
      }
    } else {
      console.warn('[ManualScan] step-selector element not found')
    }
  }
  
  // Try multiple times with increasing delays
  setTimeout(checkAndConnectStepSelector, 100)
  setTimeout(checkAndConnectStepSelector, 500)
  setTimeout(checkAndConnectStepSelector, 1000)
  setTimeout(checkAndConnectStepSelector, 2000)
  
  // Also check after DOMContentLoaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      setTimeout(checkAndConnectStepSelector, 100)
    })
  }
  
  // Also check after window load
  window.addEventListener('load', function() {
    setTimeout(checkAndConnectStepSelector, 100)
  })
} 