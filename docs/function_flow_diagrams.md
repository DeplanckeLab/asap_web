# Function Flow Diagrams

## 1. Initial Page Load Flow

```
┌─────────────────┐
│   connect()     │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│initializeIndexedDB│    │setupInteractionSystem│
└─────────────────┘    └─────────────────────┘
          │                        │
          ▼                        ▼
┌─────────────────┐    ┌─────────────────────┐
│initializeTooltip│    │   updateEmbeddings  │
└─────────────────┘    └─────────┬───────────┘
                                │
                                ▼
                    ┌─────────────────────┐
                    │ preloadAllMetadata  │
                    └─────────────────────┘
```

## 2. Embedding Selection Flow

```
┌─────────────────┐
│ updateMetadata  │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│loadMetadataCoord│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│loadSingleMetadata│   │loadMetadataFromIndex│
└─────────┬───────┘    └─────────────────────┘
          │                        │
          ▼                        ▼
┌─────────────────┐    ┌─────────────────────┐
│decompressBinary │    │   fetch() [server]   │
└─────────┬───────┘    └─────────────────────┘
          │
          ▼
┌─────────────────┐
│storeBinaryData  │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│updateVisualizat │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│renderScatterPlot│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│renderScatterReGL│
└─────────────────┘
```

## 3. Metadata Coloring Flow

```
┌─────────────────┐
│loadAndVisualize │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│loadSingleMetadata│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│decompressDiscrete│   │decompressContinuous │
└─────────┬───────┘    └─────────────────────┘
          │                        │
          ▼                        ▼
┌─────────────────┐    ┌─────────────────────┐
│updateVisualizat │    │updateVisualizat     │
└─────────┬───────┘    └─────────┬───────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│renderPointsWith │    │renderPointsWith     │
└─────────┬───────┘    └─────────┬───────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│renderPointsReGL │    │renderPointsReGL    │
└─────────┬───────┘    └─────────┬───────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│getColoringMeta  │    │getColoringMeta      │
└─────────┬───────┘    └─────────┬───────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│calculateAndCache│    │calculateAndCache    │
└─────────┬───────┘    └─────────┬───────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│getCategoryColors│    │getColorFromGradient │
└─────────────────┘    └─────────────────────┘
```

## 4. User Interaction Flow (Zoom)

```
┌─────────────────┐
│onInteractionWheel│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│preventDefault() │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│calculateBounds  │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│updateVisualizat │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│renderAxes()     │    │renderGrid()         │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│renderCategoryLab│    │reglRenderer.setCamera│
└─────────────────┘    └─────────────────────┘
```

## 5. Point Selection Flow

```
┌─────────────────┐
│onInteractionMous│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│onPointClick     │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│showTooltip      │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│getPointColor    │    │getMetadataNameById  │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│updateSelectedCel│    │updateTooltipContent │
└─────────────────┘    └─────────────────────┘
```

## 6. Memory Management Flow

```
┌─────────────────┐
│checkMemoryHealth│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│logMemoryUsage  │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│optimizeMemory   │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│cleanupUnusedMeta│    │clearOldMetadata    │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│window.gc()      │    │updateMemoryStats    │
└─────────────────┘    └─────────────────────┘
```

## 7. Data Loading Flow

```
┌─────────────────┐
│loadMetadataCoord│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│loadSingleMetadata│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│loadMetadataFromI│    │fetch() [server]     │
└─────────┬───────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│storeMetadataInI │    │storeMetadataInI     │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│decompressBinary │    │decompressBinary     │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│storeBinaryData  │    │storeBinaryData     │
└─────────────────┘    └─────────────────────┘
```

## 8. Color Management Flow

```
┌─────────────────┐
│getColorAndAlpha │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│getColoringMeta  │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│calculateAndCache│    │getCategoryColors    │
└─────────┬───────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│getColorFromGrad │    │getColorFromGrad     │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│reglRenderer.upda│    │reglRenderer.upda    │
└─────────────────┘    └─────────────────────┘
```

## 9. Error Handling Flow

```
┌─────────────────┐
│loadMetadataCoord│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│try/catch block  │
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│success path     │    │error path           │
└─────────┬───────┘    └─────────┬───────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│storeBinaryData  │    │console.error()      │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│updateVisualizat │    │showErrorSpinner    │
└─────────────────┘    └─────────────────────┘
```

## 10. Performance Optimization Flow

```
┌─────────────────┐
│checkMemoryHealth│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐
│analyzeMemoryUsag│
└─────────┬───────┘
          │
          ▼
┌─────────────────┐    ┌─────────────────────┐
│optimizeMemory  │    │cleanupUnusedMeta    │
└─────────┬───────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│updateCacheSizes │    │clearOldMetadata    │
└─────────────────┘    └─────────────────────┘
          │                      │
          ▼                      ▼
┌─────────────────┐    ┌─────────────────────┐
│triggerGC()      │    │updateMemoryStats    │
└─────────────────┘    └─────────────────────┘
```

These flow diagrams show the key execution paths through the visualization controller, helping developers understand how different scenarios are handled and where functions interact with each other.
