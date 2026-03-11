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

import CellFilteringMetadataController from "controllers/cell_filtering_metadata_controller"
application.register("cell-filtering-metadata", CellFilteringMetadataController)
console.log('Cell filtering metadata controller registered')

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

import ViewToggleController from "controllers/view_toggle_controller"
application.register("view-toggle", ViewToggleController)
console.log('View toggle controller registered')

import ProjectSelectionController from "controllers/project_selection_controller"
application.register("project-selection", ProjectSelectionController)
console.log('Project selection controller registered')

import DeleteProjectsController from "controllers/delete_projects_controller"
application.register("delete-projects", DeleteProjectsController)
console.log('Delete projects controller registered')

import IntegrateProjectsController from "controllers/integrate_projects_controller"
application.register("integrate-projects", IntegrateProjectsController)
console.log('Integrate projects controller registered')

import ComplianceValidatorController from "controllers/compliance_validator_controller"
application.register("compliance-validator", ComplianceValidatorController)
console.log('Compliance validator controller registered')

import MetadataValidationController from "controllers/metadata_validation_controller"
application.register("metadata-validation", MetadataValidationController)
console.log('Metadata validation controller registered')

import PublicToggleController from "controllers/public_toggle_controller"
application.register("public-toggle", PublicToggleController)
console.log('Public toggle controller registered')

import ComplianceFixController from "controllers/compliance_fix_controller"
application.register("compliance-fix", ComplianceFixController)
console.log('Compliance fix controller registered')

import CloneOverlayController from "controllers/clone_overlay_controller"
application.register("clone-overlay", CloneOverlayController)
console.log('Clone overlay controller registered')

import DeFilterController from "controllers/de_filter_controller"
application.register("de-filter", DeFilterController)
console.log('DE filter controller registered')

import GeFilterController from "controllers/ge_filter_controller"
application.register("ge-filter", GeFilterController)
console.log('GE filter controller registered')

import UnarchiveStatusController from "controllers/unarchive_status_controller"
application.register("unarchive-status", UnarchiveStatusController)
console.log('Unarchive status controller registered')

import CountdownController from "controllers/countdown_controller"
application.register("countdown", CountdownController)
console.log('Countdown controller registered')

import SearchFormController from "controllers/search_form_controller"
application.register("search-form", SearchFormController)
console.log('Search form controller registered')

// Log all registered controllers
console.log('Registered controllers:', Object.keys(application.router.modulesByIdentifier))

// Step loading is now fully owned by step_selector_controller.