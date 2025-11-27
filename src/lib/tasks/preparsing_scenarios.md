# Preparsing Scenarios and UI Requirements

This document outlines the different scenarios identified from preparsing outputs and the UI requirements for each.

## Scenario Categories

### 1. Single Dataset Files
**Description**: Files that contain a single dataset/group
**UI Requirements**:
- Show dataset card with all details
- Display sample matrix
- Auto-populate form fields (nber_rows, nber_cols)
- Enable "Create Project" button immediately after preparsing

### 2. Multiple Dataset Files (Archive/TAR files)
**Description**: Files (especially archives) that contain multiple datasets/groups
**Current Behavior**: 
- Preparsing returns `list_groups` with multiple entries
- Each group has its own name, dimensions, and metadata
**UI Requirements**:
- Show list of all datasets with key info (name, cells, genes)
- Allow user to select ONE dataset
- After selection, either:
  a) Re-run preparsing with `--sel` option for that specific dataset
  b) Extract details from existing output for selected dataset
- Update UI to show selected dataset details
- Update form fields based on selected dataset

### 3. Files with Warnings
**Description**: Files that preparse successfully but have warnings
**UI Requirements**:
- Display warnings prominently but non-blockingly
- Show what the warnings mean
- Allow user to proceed despite warnings
- Provide option to dismiss warnings

### 4. Files with Errors
**Description**: Files that fail preparsing
**UI Requirements**:
- Display clear error message
- Explain what went wrong
- Suggest possible solutions
- Allow user to:
  - Retry preparsing
  - Upload different file
  - Cancel and start over

### 5. Compressed Files
**Description**: Files that need decompression (.gz, .bz2, .zip, .tar)
**Current Behavior**:
- `Basic.convert_other_formats` handles decompression
**UI Requirements**:
- Show decompression progress (if applicable)
- Display extracted file information

### 6. Special Format Files
**Description**: H5AD, Loom, H5, MTX/MEX formats
**UI Requirements**:
- Show format-specific metadata if available
- Handle format-specific quirks in display

## Implementation Plan

### Phase 1: Dataset Selection UI
1. Modify `renderPreparsingResult` to detect multiple datasets
2. If multiple datasets exist:
   - Show dataset selection interface
   - List all datasets with details
   - Add radio buttons or selection UI
   - Disable "Create Project" until selection is made
3. On dataset selection:
   - Store selected dataset name/index
   - Update displayed dataset card
   - Update form fields

### Phase 2: Re-running Preparsing for Selected Dataset
1. Modify preparsing service to accept `selected_dataset` parameter
2. If `selected_dataset` is provided:
   - Pass `--sel 'dataset_name'` to preparsing script
   - Re-run preparsing with dataset filter
   - Update websocket with new results
3. Frontend:
   - Show loading state during re-preparsing
   - Update UI when new results arrive

### Phase 3: Error and Warning Handling
1. Improve warning display UI
2. Add error recovery options
3. Provide helpful error messages

## Data Structure

The preparsing output structure:
```json
{
  "detected_format": "RAW_TEXT",
  "list_groups": [
    {
      "group": "dataset_name",
      "nber_cols": 6,
      "nber_rows": 47729,
      "is_count": 1,
      "genes": "['gene1', 'gene2', ...]",
      "cells": "['cell1', 'cell2', ...]",
      "matrix": [[...], [...]],
      "metadata": {...},
      "existing_metadata": [...]
    },
    // ... more datasets
  ],
  "list_files": [...],
  "displayed_error": null,
  "metadata": {...}
}
```

## UI Flow

1. **Upload File** → Show upload progress
2. **Preparsing Starts** → Show "Preparsing in progress..."
3. **Preparsing Completes**:
   - If single dataset → Show dataset card, enable button
   - If multiple datasets → Show selection UI, disable button
   - If errors → Show error message, disable button
   - If warnings → Show warnings, enable button (but highlight warnings)
4. **User Selects Dataset** (if multiple):
   - Show loading state
   - Re-run preparsing for selected dataset
   - Update UI with selected dataset details
   - Enable button
5. **User Clicks "Create Project"** → Submit form with all data

