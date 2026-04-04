# Visualization Controller Documentation

## Overview
The `visualization_controller.js` is a Stimulus controller that manages interactive scatter plot visualizations using either PixiJS or RegL rendering engines. It handles metadata loading, coordinate visualization, user interactions, and performance optimization.

## Function Categories

### 1. Core Lifecycle Functions

#### `connect()`
- **Purpose**: Initializes the controller when connected to DOM
- **Key Actions**:
  - Sets renderer type to 'regl'
  - Initializes IndexedDB for metadata storage
  - Sets up auto-loading of first embedding
  - Configures interaction system and tooltips
- **Dependencies**: `initializeIndexedDB()`, `setupInteractionSystem()`, `initializeTooltip()`

#### `disconnect()`
- **Purpose**: Cleanup when controller disconnects
- **Key Actions**:
  - Removes event listeners
  - Destroys RegL renderer
  - Cleans up resources
- **Dependencies**: None

### 2. Data Management Functions

#### `loadMetadataCoordinates(metadataId)`
- **Purpose**: Loads coordinate data for a specific metadata ID
- **Key Actions**:
  - Fetches from server or IndexedDB cache
  - Handles binary data decompression
  - Stores data in memory cache
- **Dependencies**: `loadSingleMetadataVector()`, `decompressBinaryCoordinates()`

#### `loadSingleMetadataVector(metadataId)`
- **Purpose**: Loads individual metadata vector with caching
- **Key Actions**:
  - Checks IndexedDB cache first
  - Falls back to server fetch
  - Handles compression/decompression
- **Dependencies**: `loadMetadataFromIndexedDB()`, `storeMetadataInIndexedDB()`

#### `storeBinaryMetadataData(data)`
- **Purpose**: Stores binary metadata data in memory
- **Key Actions**:
  - Validates data structure
  - Stores in `this.metadataData`
  - Triggers visualization update
- **Dependencies**: `updateVisualizationWithMetadata()`

### 3. Rendering Functions

#### `renderScatterPlot(coordinates)`
- **Purpose**: Main rendering function with renderer dispatch
- **Key Actions**:
  - Dispatches to RegL version
  - Handles coordinate normalization
  - Updates UI elements
- **Dependencies**: `renderScatterPlotReGL()`, `renderAxes()`, `renderGrid()`

#### `renderScatterPlotReGL(coordinates)`
- **Purpose**: RegL-specific scatter plot rendering
- **Key Actions**:
  - Calculates bounds and normalization
  - Sets up RegL renderer
  - Renders points with WebGL
- **Dependencies**: `calculateBounds()`, `getAdjustedBounds()`, `normalizeX()`, `normalizeY()`

#### `renderPointsWithCurrentColoring()`
- **Purpose**: Renders points with current color scheme
- **Key Actions**:
  - Dispatches to RegL version
  - Handles metadata coloring
  - Updates point visibility
- **Dependencies**: `renderPointsWithCurrentColoringReGL()`

#### `renderPointsWithCurrentColoringReGL()`
- **Purpose**: RegL-specific point coloring
- **Key Actions**:
  - Applies discrete/continuous coloring
  - Updates RegL renderer colors
  - Handles point reordering
- **Dependencies**: `getColoringMetadataVector()`, `calculateAndCacheColors()`

### 4. Interaction Functions

#### `onInteractionWheel(event)`
- **Purpose**: Handles mouse wheel zooming
- **Key Actions**:
  - Prevents default scroll behavior
  - Calculates zoom bounds
  - Updates visualization
- **Dependencies**: `updateVisualizationBounds()`, `renderAxes()`, `renderGrid()`

#### `onInteractionMouseDown(event)`
- **Purpose**: Handles mouse down for panning/selection
- **Key Actions**:
  - Sets panning state
  - Records mouse position
  - Handles point selection
- **Dependencies**: `onPointClick()`, `showTooltip()`

#### `onInteractionMouseMove(event)`
- **Purpose**: Handles mouse movement during interactions
- **Key Actions**:
  - Updates panning if active
  - Updates tooltip position
  - Handles lasso selection
- **Dependencies**: `updateTooltipPosition()`, `updateLassoSelection()`

### 5. Color Management Functions

#### `getColorAndAlpha(pointIndex)`
- **Purpose**: Gets color and alpha for a specific point
- **Key Actions**:
  - Handles selection coloring
  - Applies metadata coloring
  - Manages transparency
- **Dependencies**: `getColoringMetadataVector()`, `getColorFromGradient()`

#### `getColoringMetadataVector()`
- **Purpose**: Determines which metadata is used for coloring
- **Key Actions**:
  - Checks for active legends
  - Returns appropriate metadata vector
  - Handles fallback logic
- **Dependencies**: None

#### `calculateAndCacheColors(coloringMetadataVector)`
- **Purpose**: Pre-calculates colors for performance
- **Key Actions**:
  - Handles discrete vs continuous coloring
  - Caches color calculations
  - Optimizes rendering performance
- **Dependencies**: `getCategoryColors()`, `getColorFromGradient()`

### 6. Utility Functions

#### `calculateBounds(coordinates)`
- **Purpose**: Calculates coordinate bounds
- **Key Actions**:
  - Finds min/max X and Y values
  - Returns bounds object
- **Dependencies**: None

#### `normalizeX(x, bounds)` / `normalizeY(y, bounds)`
- **Purpose**: Converts data coordinates to screen coordinates
- **Key Actions**:
  - Applies linear transformation
  - Handles plot margins
  - Returns screen pixel coordinates
- **Dependencies**: `getPlotMargins()`

#### `decompressBinaryCoordinates(arrayBuffer)`
- **Purpose**: Decompresses binary coordinate data
- **Key Actions**:
  - Handles different compression formats
  - Converts to coordinate array
  - Validates data integrity
- **Dependencies**: None

### 7. UI Management Functions

#### `renderAxes()` / `renderGrid()` / `renderCategoryLabels()`
- **Purpose**: Renders plot UI elements
- **Key Actions**:
  - Draws axes and grid lines
  - Renders category labels
  - Updates legends
- **Dependencies**: `renderAxesCanvas2D()`, `renderGridCanvas2D()`, `renderCategoryLabelsCanvas2D()`

#### `showTooltip(pointIndex, element)` / `hideTooltip()`
- **Purpose**: Manages point tooltips
- **Key Actions**:
  - Shows/hides tooltip elements
  - Updates tooltip content
  - Positions tooltip correctly
- **Dependencies**: `getPointColor()`, `getMetadataNameById()`

### 8. Performance Optimization Functions

#### `logMemoryUsage(context)`
- **Purpose**: Monitors memory usage
- **Key Actions**:
  - Logs memory statistics
  - Warns about high usage
  - Returns usage metrics
- **Dependencies**: None

#### `checkMemoryHealth()`
- **Purpose**: Comprehensive memory health check
- **Key Actions**:
  - Analyzes memory usage
  - Provides recommendations
  - Suggests optimizations
- **Dependencies**: `logMemoryUsage()`, `optimizeMemoryUsage()`

#### `optimizeMemoryUsage()`
- **Purpose**: Optimizes memory usage
- **Key Actions**:
  - Cleans up unused metadata
  - Manages cache sizes
  - Triggers garbage collection
- **Dependencies**: `cleanupUnusedMetadata()`, `clearOldMetadataFromMemory()`

## Function Call Paths

### Scenario 1: Initial Page Load
```
connect()
├── initializeIndexedDB()
├── setupInteractionSystem()
├── initializeTooltip()
├── updateEmbeddings() [auto-load]
└── preloadAllMetadata() [background]
```

### Scenario 2: Embedding Selection
```
updateMetadata()
├── loadMetadataCoordinates(metadataId)
│   ├── loadSingleMetadataVector(metadataId)
│   │   ├── loadMetadataFromIndexedDB() [cache check]
│   │   └── fetch() [server request]
│   └── decompressBinaryCoordinates()
├── storeBinaryMetadataData()
└── updateVisualizationWithMetadata()
    ├── renderScatterPlot(coordinates)
    │   └── renderScatterPlotReGL(coordinates)
    │       ├── calculateBounds()
    │       ├── getAdjustedBounds()
    │       ├── normalizeX() / normalizeY()
    │       └── reglRenderer.setPositions()
    └── renderPointsWithCurrentColoring()
        └── renderPointsWithCurrentColoringReGL()
            ├── getColoringMetadataVector()
            ├── calculateAndCacheColors()
            └── reglRenderer.updateColors()
```

### Scenario 3: Metadata Coloring
```
loadAndVisualizeMetadataVector(metadataId)
├── loadSingleMetadataVector(metadataId)
├── decompressDiscreteMetadataVector() / decompressContinuousMetadataVector()
├── updateVisualizationWithMetadataVector()
└── renderPointsWithCurrentColoring()
    └── renderPointsWithCurrentColoringReGL()
        ├── getColoringMetadataVector()
        ├── calculateAndCacheColors()
        │   ├── getCategoryColors() [discrete]
        │   └── getColorFromGradient() [continuous]
        └── reglRenderer.updateColors()
```

### Scenario 4: User Interaction (Zoom)
```
onInteractionWheel(event)
├── preventDefault()
├── calculateBounds() [new bounds]
├── updateVisualizationBounds()
│   ├── renderAxes()
│   ├── renderGrid()
│   └── renderCategoryLabels()
└── reglRenderer.setCamera()
```

### Scenario 5: Point Selection
```
onInteractionMouseDown(event)
├── onPointClick(pointIndex, element)
├── showTooltip(pointIndex, element)
│   ├── getPointColor()
│   └── getMetadataNameById()
└── updateSelectedCellsCount()
```

### Scenario 6: Memory Management
```
checkMemoryHealth()
├── logMemoryUsage()
├── optimizeMemoryUsage()
│   ├── cleanupUnusedMetadata()
│   └── clearOldMetadataFromMemory()
└── window.gc() [if available]
```

## Renderer-Specific Functions

### RegL-Specific
- `renderScatterPlot()`
- `renderPointsWithCurrentColoring()`
- `updatePointVisibility()`

### Renderer-Agnostic (Keep)
- `getColorAndAlpha()`
- `getColoringMetadataVector()`
- `calculateAndCacheColors()`
- `onInteractionWheel()`
- `onInteractionMouseDown()`
- `onInteractionMouseMove()`
- `calculateBounds()`
- `normalizeX() / normalizeY()`
- `decompressBinaryCoordinates()`
- `loadMetadataCoordinates()`
- `loadSingleMetadataVector()`
- `storeBinaryMetadataData()`
- `updateVisualizationWithMetadata()`
- `renderAxes() / renderGrid() / renderCategoryLabels()`
- `showTooltip() / hideTooltip()`
- `logMemoryUsage()`
- `checkMemoryHealth()`
- `optimizeMemoryUsage()`

## Key Dependencies

### Data Flow
1. **Metadata Loading**: `loadMetadataCoordinates()` → `loadSingleMetadataVector()` → `storeBinaryMetadataData()`
2. **Rendering**: `renderScatterPlot()` → `renderScatterPlotReGL()` → `reglRenderer.setPositions()`
3. **Coloring**: `renderPointsWithCurrentColoring()` → `renderPointsWithCurrentColoringReGL()` → `reglRenderer.updateColors()`
4. **Interactions**: `onInteractionWheel()` → `updateVisualizationBounds()` → `renderAxes() / renderGrid()`

### Performance Optimization
1. **Caching**: `calculateAndCacheColors()` → `getColoringMetadataVector()`
2. **Memory Management**: `checkMemoryHealth()` → `optimizeMemoryUsage()` → `cleanupUnusedMetadata()`
3. **IndexedDB**: `loadMetadataFromIndexedDB()` → `storeMetadataInIndexedDB()`

This documentation provides a comprehensive overview of the visualization controller's functionality, helping developers understand the codebase structure and function relationships.
