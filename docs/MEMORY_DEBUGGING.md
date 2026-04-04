# Memory Debugging Guide for Large Dataset Visualization

## Quick Memory Check in Console

The visualization now includes built-in memory monitoring. In the browser console, type:

```javascript
visualizationController.checkMemoryHealth()
```

This will show:
- Current sprite count
- Container children count
- Loaded metadata vectors
- Memory usage (Chrome/Edge only)
- Potential leaks

## Using Firefox Developer Tools

### 1. Open Firefox Developer Tools
- Press `F12` or `Ctrl+Shift+I` (Linux/Windows) or `Cmd+Option+I` (Mac)
- Go to the **"Memory"** tab

### 2. Take a Memory Snapshot
1. Click **"Take snapshot"** button
2. Wait for snapshot to complete
3. You'll see memory breakdown by object type

### 3. Monitor Memory Over Time
1. Take snapshot **before** loading visualization
2. Take snapshot **after** loading 500k cell project
3. Take snapshot **after** switching metadata several times
4. Compare snapshots to identify growth

### 4. Look for Memory Leaks

**What to check:**
- **Detached DOM nodes** - should be minimal
- **Sprites** - should stay ~500k, not grow
- **Event listeners** - check if they're accumulating
- **Metadata vectors** - should match number of metadata types, not keep growing

## Using Chrome Developer Tools (Better Memory API)

Chrome/Edge provide more detailed memory stats via `performance.memory`:

### 1. Open DevTools
- Press `F12`
- Go to **"Performance"** or **"Memory"** tab

### 2. Monitor Memory Timeline
1. Click record button
2. Interact with visualization (switch metadata, zoom, etc.)
3. Stop recording
4. Look at memory graph for:
   - Steady growth = potential leak
   - Sawtooth pattern = normal (GC cycles)
   - Sudden spikes = large allocations

### 3. Take Heap Snapshots
1. Go to **"Memory"** tab
2. Select **"Heap snapshot"**
3. Click **"Take snapshot"**
4. Repeat after operations
5. Use **"Comparison"** view to see what grew

## Automatic Memory Logging

The visualization now logs memory automatically at key points:
- `💾 [MEMORY] After creating initial sprites: X MB`
- `💾 [MEMORY] After discrete metadata update: X MB`
- `💾 [MEMORY] After numeric metadata update: X MB`

## IndexedDB Disk Storage (NEW!)

The visualization now uses **IndexedDB** to store metadata on disk instead of memory:

### How It Works:
1. **First load**: Check IndexedDB → If found, load from disk → Otherwise download from server
2. **Store to disk**: After loading, store in IndexedDB for next page reload
3. **Session strategy**: Keep all loaded metadata in memory during session for fast switching
4. **Page reload**: Load from IndexedDB (disk) instead of re-downloading from server

### Benefits:
- **No re-downloading on page reload** - saves time and bandwidth
- **Fast switching during session** - all metadata in memory for instant access
- **Persistent cache** - data survives page reloads
- **Automatic cache invalidation** - checks loom file to ensure data validity

### Check IndexedDB Status:
```javascript
visualizationController.checkMemoryHealth()
// Shows: "💾 IndexedDB initialized and available for disk storage"
```

### Clear IndexedDB Cache (if needed):
```javascript
await visualizationController.clearIndexedDBCache()
// Clears all cached metadata from disk
```

## Expected Memory Usage

For 500,000 cells:
- **Sprites**: ~500k objects × ~200 bytes = ~100 MB
- **Metadata vectors (all loaded)**: ~5-20 MB each × N metadata types
- **Textures**: ~5-10 MB
- **IndexedDB (disk)**: ~100-500 MB (not counted in RAM, used for persistence only)
- **Total RAM during session**: **~150-400 MB** (acceptable for modern browsers)
- **After page reload**: Metadata loads from IndexedDB (disk) instead of server - faster!

## Warning Signs

🚨 **If you see:**
- Memory > 80% of limit
- Memory growing continuously without stabilizing
- Memory not releasing after clearing metadata
- Browser becoming unresponsive

## Potential Solutions

### 1. Clear Metadata Cache
```javascript
visualizationController.clearLoadedMetadataVectorsCache()
visualizationController.logMemoryUsage('After clearing cache')
```

### 2. Clear Filter Cache
```javascript
visualizationController.filterCache.clear()
```

### 3. Reload Page
For large datasets, periodic page reload may be necessary to clear all memory.

### 4. Reduce Preloading
The visualization preloads all metadata in background. For very large datasets with many metadata types, this might use too much memory.

## Memory Optimization Tips

1. **Close other tabs** - Free up browser memory
2. **Use Chrome/Edge** - Better memory management than Firefox for WebGL
3. **Increase browser memory limit** - Some browsers limit heap size
4. **Monitor with DevTools** - Watch for unexpected growth patterns

## Quick Diagnostic Commands

```javascript
// Check memory health
visualizationController.checkMemoryHealth()

// Log current memory
visualizationController.logMemoryUsage('Manual check')

// Check sprite count
console.log('Sprites:', visualizationController.pointSprites?.length)

// Check container integrity
console.log('Container children:', visualizationController.animatedContainer?.children.length)

// Check for orphaned sprites
let orphaned = 0
visualizationController.pointSprites?.forEach(s => { if (s && !s.parent) orphaned++ })
console.log('Orphaned sprites:', orphaned)
```

## Firefox Specific Notes

- Firefox doesn't expose `performance.memory` - memory logs will show "not available"
- Use Firefox's Memory tool instead (F12 → Memory tab)
- Firefox may have different memory limits than Chrome
- Consider testing in Chrome if memory issues persist

