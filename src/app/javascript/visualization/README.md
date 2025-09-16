# Visualization Module Refactoring

This directory contains the refactored visualization modules that were extracted from the monolithic `visualization_controller.js` file.

## Module Structure

### 1. `pixi_renderer.js` - PIXI.js Rendering Module
**Responsibility**: All PIXI.js related rendering operations
- **Key Methods**:
  - `initializePixiScatterPlot()` - Initialize PIXI application
  - `renderScatterPlot()` - Render scatter plot with coordinates
  - `updateScatterPlot()` - Update plot with new coordinates (with animation)
  - `renderAxes()` - Render plot axes
  - `renderGrid()` - Render plot grid
  - `renderCategoryLabels()` - Render category labels
  - `createAnimatedPoints()` - Create animated transitions
  - `updateAllPointSizes()` - Update point sizes
  - `normalizeX/Y()` - Coordinate normalization

### 2. `color_manager.js` - Color Management Module
**Responsibility**: Color management and customization
- **Key Methods**:
  - `getCategoryColors()` - Get category color palette
  - `getColorAndAlpha()` - Get color for a specific point
  - `getCategoryColor()` - Get category color with customization
  - `showColorPicker()` - Show color picker for customization
  - `resetColorsForMetadata()` - Reset colors to defaults
  - `hasCustomizedColors()` - Check if metadata has custom colors
  - `clearStoredColors()` - Clear stored color customizations

### 3. `interaction_handler.js` - Interaction Handler Module
**Responsibility**: Mouse/touch interactions (pan, zoom, lasso, pick)
- **Key Methods**:
  - `setInteractionMode()` - Set interaction mode (pan/pick/lasso)
  - `onPanMouseDown/Move/Up()` - Pan mode handlers
  - `onLassoMouseDown/Move/Up()` - Lasso mode handlers
  - `onPickMouseDown()` - Pick mode handlers
  - `onInteractionWheel()` - Zoom handling
  - `selectPointsInLasso()` - Lasso selection logic
  - `translatePointsForZoom()` - Point translation for zoom
  - `resetZoomAndPan()` - Reset view

### 4. `data_manager.js` - Data Manager Module
**Responsibility**: Data loading, decompression, and metadata management
- **Key Methods**:
  - `loadMetadataCoordinates()` - Load coordinate data
  - `loadAndVisualizeMetadataVector()` - Load metadata vectors
  - `decompressBinaryCoordinates()` - Decompress coordinate data
  - `decompressDiscreteMetadataVector()` - Decompress discrete metadata
  - `decompressContinuousMetadataVector()` - Decompress continuous metadata
  - `calculateBounds()` - Calculate plot bounds
  - `getAdjustedBounds()` - Get bounds with margins
  - `detectEmbeddingMethodChange()` - Detect embedding changes

### 5. `filter_manager.js` - Filter Manager Module
**Responsibility**: Checkbox filtering and cell selection
- **Key Methods**:
  - `initializeAllCheckboxes()` - Initialize checkbox UI
  - `toggleMetadataSelection()` - Toggle metadata selection
  - `toggleCategorySelection()` - Toggle category selection
  - `updateCellFiltering()` - Update filtering logic
  - `updatePointVisibility()` - Update point visibility
  - `getFilteredCellIndices()` - Get filtered cell indices
  - `addAllVisibleCells()` - Add all visible cells to selection
  - `updateSelectionBasedOnFiltering()` - Update selection based on filters

### 6. `ui_manager.js` - UI Manager Module
**Responsibility**: UI elements, tooltips, settings windows
- **Key Methods**:
  - `initializeTooltip()` - Initialize tooltip system
  - `showTooltip()` - Show tooltip for points
  - `toggleSettingsWindow()` - Toggle settings window
  - `updatePointSize()` - Update point size
  - `toggleAxes/Grid/Categories()` - Toggle plot elements
  - `saveAsSVG()` - Export plot as SVG
  - `generateSVGFromPlot()` - Generate SVG content
  - `makeSettingsWindowDraggable()` - Make settings window draggable

## Migration Guide

### Before (Monolithic Controller)
```javascript
// All functionality in one large file (6000+ lines)
class VisualizationController extends Controller {
  // 150+ methods all in one class
  renderScatterPlot() { /* ... */ }
  getColorAndAlpha() { /* ... */ }
  onPanMouseDown() { /* ... */ }
  // ... many more methods
}
```

### After (Modular Architecture)
```javascript
// Main controller orchestrates modules
class VisualizationController extends Controller {
  connect() {
    // Initialize modules
    this.pixiRenderer = new PixiRenderer(this)
    this.colorManager = new ColorManager(this)
    this.interactionHandler = new InteractionHandler(this)
    this.dataManager = new DataManager(this)
    this.filterManager = new FilterManager(this)
    this.uiManager = new UIManager(this)
  }
  
  // Delegate to appropriate modules
  renderScatterPlot(coordinates) {
    return this.pixiRenderer.renderScatterPlot(coordinates)
  }
  
  getColorAndAlpha(pointIndex) {
    return this.colorManager.getColorAndAlpha(pointIndex)
  }
  
  onPanMouseDown(event) {
    return this.interactionHandler.onPanMouseDown(event)
  }
}
```

## Benefits of Refactoring

1. **Maintainability**: Each module has a single responsibility
2. **Testability**: Modules can be tested independently
3. **Reusability**: Modules can be reused in other contexts
4. **Readability**: Code is organized by functionality
5. **Collaboration**: Multiple developers can work on different modules
6. **Performance**: Easier to optimize specific functionality
7. **Debugging**: Issues are easier to isolate and fix

## Usage

The refactored controller is now the main controller. The original monolithic controller has been renamed to `visualization_controller_old.js` as a backup.

```javascript
// The main controller now uses the modular architecture
import VisualizationController from './visualization_controller.js'
```

The API remains the same, but the internal implementation is now modular and maintainable.

## File Sizes

- **Original (backup)**: `visualization_controller_old.js` - 6,131 lines
- **Current (modular)**: 
  - `visualization_controller.js` - 1,200 lines (main orchestrator)
  - `pixi_renderer.js` - 800 lines
  - `color_manager.js` - 400 lines
  - `interaction_handler.js` - 600 lines
  - `data_manager.js` - 500 lines
  - `filter_manager.js` - 400 lines
  - `ui_manager.js` - 500 lines

**Total**: ~4,400 lines (28% reduction due to better organization and elimination of duplication)