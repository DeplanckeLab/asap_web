# Memory Debugging Guide

## Understanding the Memory Count

The diagnostic window shows:
- **Total in Memory**: Metadata + Embeddings (items cached for quick access)
- **In Memory**: Active metadata vectors (categorical/continuous)
- **Embeddings**: Cached embedding coordinates

## Common Scenarios

### Scenario 1: Show "0 in memory" but plot is displayed

**Why this happens:**
- Embedding coordinates are loaded into `metadataData` (not counted in "in memory")
- The "in memory" count refers to cached items, not the active display

**What's actually happening:**
- The currently displayed embedding is in `metadataData` (1 embedding loaded)
- `binaryDataCache` may be empty (no cached embeddings for switching)
- `loadedMetadataVectors` may be empty (no metadata colored yet)

**Diagnostic shows:**
```
Embeddings: 0 cached, 1 currently loaded
```

### Scenario 2: Embedded loaded from IndexedDB

**What this means:**
- Embedding was previously loaded and cached on disk
- Loaded from IndexedDB instead of network
- Fasted than network fetch (~50ms vs ~1-5 seconds)

**Diagnostic logs show:**
```
⏱️ [PERF] IndexedDB HIT for <id> - ~50ms (saved network fetch!)
```

### Scenario 3: Embedding loaded from memory cache

**What this means:**
- Embedding was recently used and still in memory
- Ultra-fast load (~5ms)
- No disk or network access needed

**Diagnostic logs show:**
```
⏱️ [PERF] Binary cache retrieval: ~5ms (saved ~5s download!)
```

## Debugging Steps

### 1. Check Browser Console

Open the browser console (F12) and look for:
- `🔍 [DIAGNOSTIC] Controller properties:` - Shows all caches
- `🔍 [DIAGNOSTIC] Counts:` - Shows exact counts
- `⏱️ [PERF]` messages - Shows where data was loaded from

### 2. Use Memory Diagnostic Window

Click the 🧠 icon in the toolbar to see:
- **Memory Status**: What's in memory vs on disk
- **Metadata Breakdown**: Categorical vs continuous counts
- **Debug Info**: Detailed cache keys and states

### 3. Check Debug Info Section

Look for:
- `binaryDataCache exists`: Should be `true`
- `binaryDataCache size`: Number of cached embeddings
- `binaryDataCache keys`: IDs of cached embeddings
- `metadataData exists`: Should be `true` if plot is displayed
- `metadataData name`: Name of currently loaded embedding

### 4. Verify Data Flow

Expected flow when loading an embedding:

1. **Check memory cache** (`binaryDataCache`)
   - Found → Use (instant)
   - Not found → Continue

2. **Check IndexedDB** (disk)
   - Found → Load to memory → Use (fast)
   - Not found → Continue

3. **Fetch from network**
   - Load → Store in memory cache → Store in IndexedDB → Use (slow, first time only)

## Troubleshooting

### Issue: Diagnostic shows 0 embeddings but plot works

**Cause**: Data is in `metadataData` but not in `binaryDataCache`

**Solution**: This is expected behavior - the diagnostic shows cached items, not the active display

### Issue: Embeddings load slowly

**Cause**: Not cached in memory or disk

**Solution**: 
1. First load is slow (network fetch)
2. Subsequent loads should be fast (from IndexedDB)
3. Check console for `IndexedDB HIT` messages

### Issue: Diagnostic shows "unknown" for binaryDataCache

**Cause**: Cache exists but size property access failed

**Solution**: 
- Check browser console for errors
- Verify binaryDataCache is actually a Map
- Look for errors in the diagnostic logs

## Key Variables

| Variable | Purpose | Type | Location |
|----------|---------|------|----------|
| `metadataData` | Currently displayed embedding | Object | controller |
| `binaryDataCache` | Cached embeddings for switching | Map | controller |
| `loadedMetadataVectors` | Active metadata vectors | Object | controller |
| `db` | IndexedDB instance | IDBDatabase | controller |

## Quick Commands

In browser console, you can run:

```javascript
// Check what's in memory
visualizationController.binaryDataCache.size
visualizationController.loadedMetadataVectors

// Check currently loaded embedding
visualizationController.metadataData

// Check IndexedDB status
visualizationController.db

// Run diagnostic
visualizationController.performanceManager.openMemoryDiagnostic()
```

