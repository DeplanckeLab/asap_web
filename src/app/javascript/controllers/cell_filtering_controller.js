import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    hData: Object,
    hFloat: Object,
    listP: Array,
    nberCells: Number,
    readOnly: Boolean,
    discardedCols: Array,
    parsingRunId: Number,
    outputAttrName: String,
    outputFilename: String
  }

  static targets = ["result", "filtered", "plot", "matrixDatasetSelect", "matrixDatasetHidden", "inputMatrixHidden", "submitButton", "submitSpinner"]

  isFilterEnabled(disableBtn) {
    return disableBtn && disableBtn.classList.contains("text-red-700") && !disableBtn.classList.contains("bg-red-50");
  }

  connect() {
    this.isRecomputing = false;
    this.lastDiscardedCount = 0;
    this.toggleSubmitSpinner(false);

    console.log("=== CELL FILTERING CONTROLLER CONNECTED ===");
    console.log("Element:", this.element);
    console.log("Element HTML (first 500 chars):", this.element.outerHTML.substring(0, 500));
    
    // When content is loaded via AJAX, script tags don't execute automatically
    // We need to manually find and execute them
    // Script tag might be before the element, so check parent and siblings too
    let scripts = this.element.querySelectorAll('script');
    console.log("Found", scripts.length, "script tags inside element");
    
    // Also check if script is a sibling (before the element)
    let parent = this.element.parentElement;
    if (parent) {
      const allScripts = parent.querySelectorAll('script');
      console.log("Found", allScripts.length, "script tags in parent element");
      // Filter to only scripts that are before this element
      const scriptsBefore = Array.from(allScripts).filter(script => {
        return script.compareDocumentPosition(this.element) & Node.DOCUMENT_POSITION_PRECEDING;
      });
      console.log("Found", scriptsBefore.length, "script tags before this element");
      scripts = Array.from(scripts).concat(scriptsBefore);
    }
    
    // Also check the element itself and previous siblings
    let prevSibling = this.element.previousElementSibling;
    while (prevSibling) {
      if (prevSibling.tagName === 'SCRIPT') {
        console.log("Found script tag as previous sibling");
        scripts = Array.from(scripts).concat([prevSibling]);
      }
      prevSibling = prevSibling.previousElementSibling;
    }
    
    console.log("Total script tags to execute:", scripts.length);
    
    scripts.forEach((script, index) => {
      try {
        console.log(`Executing script tag ${index + 1}...`);
        if (script.src) {
          // External script - load it
          console.log(`Loading external script: ${script.src}`);
          const newScript = document.createElement('script');
          newScript.src = script.src;
          newScript.onload = () => {
            console.log(`External script ${index + 1} loaded: ${script.src}`);
          };
          newScript.onerror = (e) => {
            console.error(`Error loading external script ${index + 1}:`, e);
          };
          document.head.appendChild(newScript);
        } else {
          // Inline script - execute it
          console.log(`Script content (first 200 chars):`, script.textContent.substring(0, 200));
          const newScript = document.createElement('script');
          newScript.textContent = script.textContent;
          document.head.appendChild(newScript);
          document.head.removeChild(newScript);
          console.log(`Script tag ${index + 1} executed successfully`);
          console.log("window.cellFilteringData after execution:", window.cellFilteringData);
        }
      } catch(e) {
        console.error(`Error executing script tag ${index + 1}:`, e);
      }
    });
    
    // Wait a moment for scripts to execute, then get data
    setTimeout(() => {
      this.initialize();
    }, 100);
  }
  
  initialize() {
    this.updateInputMatrixPayload()

    // Get data from window object (set by script tag in the view)
    let hData, hFloat, listP, nberCells;
    
    if (typeof window.cellFilteringData !== 'undefined' && window.cellFilteringData.hData) {
      hData = window.cellFilteringData.hData;
      hFloat = window.cellFilteringData.hFloat || {};
      listP = window.cellFilteringData.listP || [];
      nberCells = window.cellFilteringData.nberCells || 0;
      console.log("Loaded data from window.cellFilteringData");
      console.log("hData keys:", Object.keys(hData || {}));
    } else {
      console.error("window.cellFilteringData not found!");
      console.log("window.cellFilteringData:", window.cellFilteringData);
      console.log("Available window properties:", Object.keys(window).filter(k => k.toLowerCase().includes('cell')));
      this.updateCounts(0, 0);
      return;
    }
    
    console.log("hData keys:", Object.keys(hData || {}));
    console.log("nberCells:", nberCells);
    
    if (!hData || Object.keys(hData).length === 0) {
      console.error("No h_data available");
      this.updateCounts(0, 0);
      return;
    }

    this.h_discarded = {};
    this.h_data = hData;
    this.h_float = hFloat || {};
    this.list_p = listP || [];
    this.nber_cells = nberCells || 0;
    
    // Wait for pako library to be available before decompressing
    this.waitForPako(() => {
      // Decompress data
      this.decompressData();

      // Read-only mode for results pages: use persisted discarded cells from run attrs
      // and render plots without relying on editable form fields.
      if (this.readOnlyValue) {
        const discarded = Array.isArray(this.discardedColsValue) ? this.discardedColsValue : [];
        this.h_discarded = {};
        discarded.forEach((idx) => {
          const i = parseInt(idx, 10);
          if (!Number.isNaN(i)) this.h_discarded[i] = 1;
        });
        const discardedCount = Object.keys(this.h_discarded).length;
        const keptCount = Math.max(0, this.nber_cells - discardedCount);
        this.updateCounts(keptCount, discardedCount);
        this.plot(1);
        return;
      }

      // Editable form mode
      this.changeCutoff(false);
      this.plot(1);
    });
  }
  
  waitForPako(callback, maxAttempts = 20, attempt = 0) {
    if (typeof pako !== 'undefined') {
      console.log("pako library is available");
      callback();
      return;
    }
    
    if (attempt >= maxAttempts) {
      console.error("pako library not available after", maxAttempts, "attempts");
      // Try to continue anyway, decompression will fail gracefully
      callback();
      return;
    }
    
    console.log("Waiting for pako library... (attempt", attempt + 1, "of", maxAttempts + ")");
    setTimeout(() => {
      this.waitForPako(callback, maxAttempts, attempt + 1);
    }, 100);
  }
  
  initializeWithData(hData, hFloat, listP, nberCells) {
    
    console.log("hData keys:", Object.keys(hData || {}));
    console.log("nberCells:", nberCells);
    
    if (!hData || Object.keys(hData).length === 0) {
      console.error("No h_data available");
      this.updateCounts(0, 0);
      return;
    }

    this.h_discarded = {};
    this.h_data = hData;
    this.h_float = hFloat || {};
    this.list_p = listP || [];
    this.nber_cells = nberCells || 0;
    
    // Decompress data
    this.decompressData();
    
    // Initialize UI
    this.changeCutoff(false);
    this.plot(1);
  }

  decompressData() {
    console.log("Starting data decompression...");
    const list_p = Object.keys(this.h_data);
    const h_float = this.h_float || {};
    
    for (let i = 0; i < list_p.length; i++) {
      const k = list_p[i];
      if (this.h_data[k] && this.h_data[k].values) {
        try {
          const values = this.h_data[k].values;
          
          // Check if values are already an array (already decompressed)
          if (Array.isArray(values)) {
            console.log(k, "values are already an array, length:", values.length);
            // Values are already decompressed, use them directly
            this.h_data[k].values = values;
          } else if (typeof values === 'string') {
            // Values are a base64 string, need to decompress
            console.log("Decompressing", k, "from base64 string...");
            const uncompressed = this.uncompress(values);
            console.log("Uncompressed", k, "length:", uncompressed.length);
            this.h_data[k].values = this.convert_short_endians_to_array(uncompressed, h_float[k] || 0);
            console.log("Converted", k, "to array, length:", this.h_data[k].values.length);
          } else {
            console.warn("Unknown values type for", k, ":", typeof values);
          }
        } catch(e) {
          console.error("Error processing", k, ":", e);
        }
      } else {
        console.warn("No values found for", k);
      }
    }
    console.log("Data decompression complete");
  }

  uncompress(base64data) {
    try {
      if (typeof pako === 'undefined') {
        console.error("pako library is not loaded. Please include pako.min.js");
        return new Uint8Array(0);
      }
      
      if (!base64data || typeof base64data !== 'string') {
        console.error("Invalid base64data:", typeof base64data, base64data);
        return new Uint8Array(0);
      }
      
      // Clean the base64 string - remove whitespace, newlines, and quotes if JSON-encoded
      let cleanBase64 = base64data.trim();
      
      // Remove surrounding quotes if it's a JSON string
      if ((cleanBase64.startsWith('"') && cleanBase64.endsWith('"')) ||
          (cleanBase64.startsWith("'") && cleanBase64.endsWith("'"))) {
        cleanBase64 = cleanBase64.slice(1, -1);
      }
      
      // Remove all whitespace and newlines
      cleanBase64 = cleanBase64.replace(/\s/g, '').replace(/\n/g, '');
      
      // Validate base64 format (base64 can contain A-Z, a-z, 0-9, +, /, and = for padding)
      if (!/^[A-Za-z0-9+/=]*$/.test(cleanBase64)) {
        console.error("Invalid base64 characters in string");
        console.error("First 100 chars:", cleanBase64.substring(0, 100));
        console.error("Invalid chars found:", cleanBase64.match(/[^A-Za-z0-9+/=]/g));
        return new Uint8Array(0);
      }
      
      const compressData = atob(cleanBase64);
      const binData = new Uint8Array(compressData.split('').map(e => e.charCodeAt(0)));
      return pako.inflate(binData);
    } catch(e) {
      console.error("Error in uncompress:", e);
      console.error("base64data type:", typeof base64data);
      console.error("base64data length:", base64data ? base64data.length : 0);
      console.error("base64data first 50 chars:", base64data ? base64data.substring(0, 50) : 'null');
      return new Uint8Array(0);
    }
  }

  convert_short_endians_to_array(se, is_float) {
    try {
      const a = [];
      for (let i = 0; i < se.length / 2; i++) {
        const bytes = new Uint8Array([se[i*2], se[i*2+1], 0, 0]);
        if (is_float == 1) {
          a.push(new Uint32Array(bytes.buffer)[0] / 10);
        } else {
          a.push(new Uint32Array(bytes.buffer)[0]);
        }
      }
      return a;
    } catch(e) {
      console.error("Error in convert_short_endians_to_array:", e);
      return [];
    }
  }

  changeCutoff(update_manually_discarded) {
    this.beginRecompute();
    console.log("changeCutoff called");
    try {
      if (!this.h_data || !this.h_data.depth || !this.h_data.depth.values) {
        console.error("changeCutoff: Data not available");
        this.updateCounts(0, 0);
        return;
      }

      this.h_manually_discarded = {};
      this.h_discarded = {};
      
      // Handle manually discarded from metadata checkboxes
      const checkboxes = document.querySelectorAll('#list_of_cats input[type="checkbox"]');
      checkboxes.forEach(checkbox => {
        if (!checkbox.checked) {
          let indices = [];
          try {
            indices = JSON.parse(checkbox.dataset.cellIndices || "[]");
          } catch (e) {
            indices = [];
          }
          indices.forEach((i) => {
            const idx = parseInt(i, 10);
            if (!Number.isNaN(idx)) {
              this.h_manually_discarded[idx] = 1;
            }
          });
        }
      });
      
      const list_manually_discarded = [];
      const depth_values_length = this.h_data.depth.values ? this.h_data.depth.values.length : 0;
      console.log("Processing", depth_values_length, "cells");
      
      for (let i = 0; i < depth_values_length; i++) {
        if (this.h_manually_discarded[i]) {
          list_manually_discarded.push(i);
          this.h_discarded[i] = 1;
        }
      }
      
      // Get filter parameters
      const list_p = this.list_p || [];
      const list_p_lower = list_p.filter(p => p.type === 'lower').map(p => p.name);
      const list_p_greater = list_p.filter(p => p.type === 'greater').map(p => p.name);
      
      // Apply filters
      for (let i = 0; i < list_p_lower.length; i++) {
        const param_name = list_p_lower[i];
        const disableBtn = document.getElementById('disable-btn-' + param_name);
        if (this.isFilterEnabled(disableBtn)) {
          if (this.h_data[param_name]) {
            const threshold = parseFloat(document.getElementById(param_name + '_value').value);
            const values = this.h_data[param_name].values;
            for (let j = 0; j < values.length; j++) {
              if (values[j] <= threshold) {
                this.h_discarded[j] = 1;
              }
            }
          }
        }
      }
      
      for (let i = 0; i < list_p_greater.length; i++) {
        const param_name = list_p_greater[i];
        const disableBtn = document.getElementById('disable-btn-' + param_name);
        if (this.isFilterEnabled(disableBtn)) {
          if (this.h_data[param_name]) {
            const threshold = parseFloat(document.getElementById(param_name + '_value').value);
            const values = this.h_data[param_name].values;
            for (let j = 0; j < values.length; j++) {
              if (values[j] >= threshold) {
                this.h_discarded[j] = 1;
              }
            }
          }
        }
      }
      
      const list_discarded = Object.keys(this.h_discarded);
      const kept_count = this.nber_cells - list_discarded.length;
      
      console.log("changeCutoff: Updating UI - Kept:", kept_count, "Discarded:", list_discarded.length);
      
      // Update hidden fields
      const discardedColsInput = document.getElementById('attrs_discarded_cols');
      if (discardedColsInput) {
        discardedColsInput.value = JSON.stringify({ discarded_cols: list_discarded });
      }
      const manuallyDiscardedInput = document.getElementById('attrs_manually_discarded_cols');
      if (manuallyDiscardedInput) {
        manuallyDiscardedInput.value = JSON.stringify({ manually_discarded_cols: list_manually_discarded });
      }
      const nberManuallyDiscardedInput = document.getElementById('attrs_nber_manually_discarded_cols');
      if (nberManuallyDiscardedInput) {
        nberManuallyDiscardedInput.value = list_manually_discarded.length;
      }
      
      // Update UI
      this.updateCounts(kept_count, list_discarded.length);
      
      // Update plot
      const plotSelect = document.getElementById('sel_plot');
      if (plotSelect) {
        this.plot(parseInt(plotSelect.value) || 1);
      }
    } finally {
      this.endRecompute();
    }
  }

  updateCounts(kept, discarded) {
    this.lastDiscardedCount = discarded;
    if (this.hasResultTarget) {
      this.resultTarget.innerHTML = `${kept.toLocaleString()}`;
    }
    if (this.hasFilteredTarget) {
      this.filteredTarget.innerHTML = `${discarded.toLocaleString()}`;
    }
    if (this.hasSubmitButtonTarget) {
      if (this.isRecomputing) {
        this.setSubmitButtonState(true, "Recomputing...", "Recomputing filters...");
      } else {
        this.applySubmitAvailability();
      }
    }
  }

  setSubmitButtonState(disabled, titleText = "") {
    if (!this.hasSubmitButtonTarget) return;
    this.submitButtonTarget.disabled = disabled;
    this.submitButtonTarget.classList.toggle("opacity-50", disabled);
    this.submitButtonTarget.classList.toggle("cursor-not-allowed", disabled);
    this.submitButtonTarget.classList.toggle("cursor-pointer", !disabled);
    this.submitButtonTarget.title = titleText;
  }

  toggleSubmitSpinner(show) {
    if (!this.hasSubmitSpinnerTarget) return;
    this.submitSpinnerTarget.classList.toggle("hidden", !show);
  }

  beginRecompute() {
    this.isRecomputing = true;
    this.toggleSubmitSpinner(true);
    this.setSubmitButtonState(true, "Recomputing filters...");
  }

  endRecompute() {
    this.isRecomputing = false;
    this.toggleSubmitSpinner(false);
    this.applySubmitAvailability();
  }

  applySubmitAvailability() {
    if (!this.hasSubmitButtonTarget) return;
    const disabled = this.lastDiscardedCount <= 0;
    this.setSubmitButtonState(disabled, disabled ? "At least one discarded cell is required." : "");
  }

  plot(plot_i) {
    console.log("plot:", plot_i);
    
    if (typeof Plotly === 'undefined') {
      console.error("Plotly is not loaded");
      return;
    }
    
    const traces = [];
    let layout = {};
    
    if (plot_i == 1) {
      const vals = this.h_data.depth.values;
      const sorted_indices = [...vals.keys()].sort((a, b) => vals[b] - vals[a]);
      const color_vector = sorted_indices.map((i) => (this.h_discarded[i]) ? '#CCCCCC' : 'red');
      traces.push({
        x: [...Array(vals.length).keys()],
        y: sorted_indices.map(x => vals[x]),
        marker: { color: color_vector },
        legendgroup: 'group',
        mode: 'lines+markers',
        type: 'scattergl'
      });
      layout = {
        title: 'Ordered depth by cell',
        xaxis: { title: 'Cell barcodes', type: 'log' },
        yaxis: { title: 'UMI counts', type: 'log' },
        hovermode: "closest"
      };
    } else if (plot_i == 2) {
      traces.push(
        { y: this.h_data.detected_genes.values, name: 'All', marker: { color: 'blue' }, type: 'violin' },
        { y: this.h_data.detected_genes.values.filter((e, i) => !this.h_discarded[i]), name: 'Kept', marker: { color: 'red' }, type: 'violin' },
        { y: this.h_data.detected_genes.values.filter((e, i) => this.h_discarded[i]), name: 'Discarded', marker: { color: '#CCCCCC' }, type: 'violin' }
      );
      layout = { title: 'Detected genes', yaxis: { zeroline: false }, hovermode: "closest" };
    } else if (plot_i == 3) {
      traces.push(
        { y: this.h_data.depth.values, name: 'All', marker: { color: 'blue' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.depth.values.filter((e, i) => !this.h_discarded[i]), name: 'Kept', marker: { color: 'red' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.depth.values.filter((e, i) => this.h_discarded[i]), name: 'Discarded', marker: { color: '#CCCCCC' }, mode: 'lines+markers', type: 'violin' }
      );
      layout = { title: 'Depth', yaxis: { zeroline: false }, hovermode: "closest" };
    } else if (plot_i == 4) {
      traces.push(
        { y: this.h_data.protein_coding.values, name: 'All', marker: { color: 'blue' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.protein_coding.values.filter((e, i) => !this.h_discarded[i]), name: 'Kept', marker: { color: 'red' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.protein_coding.values.filter((e, i) => this.h_discarded[i]), name: 'Discarded', marker: { color: '#CCCCCC' }, mode: 'lines+markers', type: 'violin' }
      );
      layout = { title: 'Percent protein-coding genes', yaxis: { zeroline: false }, hovermode: "closest" };
    } else if (plot_i == 5) {
      traces.push(
        { y: this.h_data.mito.values, name: 'All', marker: { color: 'blue' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.mito.values.filter((e, i) => !this.h_discarded[i]), name: 'Kept', marker: { color: 'red' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.mito.values.filter((e, i) => this.h_discarded[i]), name: 'Discarded', marker: { color: '#CCCCCC' }, mode: 'lines+markers', type: 'violin' }
      );
      layout = { title: 'Percent mitochondrial genes', yaxis: { zeroline: false }, hovermode: "closest" };
    } else if (plot_i == 6) {
      traces.push(
        { y: this.h_data.ribo.values, name: 'All', marker: { color: 'blue' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.ribo.values.filter((e, i) => !this.h_discarded[i]), name: 'Kept', marker: { color: 'red' }, mode: 'lines+markers', type: 'violin' },
        { y: this.h_data.ribo.values.filter((e, i) => this.h_discarded[i]), name: 'Discarded', marker: { color: '#CCCCCC' }, mode: 'lines+markers', type: 'violin' }
      );
      layout = { title: 'Percent ribosomal genes', yaxis: { zeroline: false }, hovermode: "closest" };
    } else if (plot_i == 7) {
      traces.push(
        { x: this.h_data.depth.values.filter((e, i) => !this.h_discarded[i]), y: this.h_data.mito.values.filter((e, i) => !this.h_discarded[i]), name: 'Kept', marker: { color: 'red' }, mode: 'markers', type: 'scattergl' },
        { x: this.h_data.depth.values.filter((e, i) => this.h_discarded[i]), y: this.h_data.mito.values.filter((e, i) => this.h_discarded[i]), name: 'Discarded', marker: { color: '#CCCCCC' }, mode: 'markers', type: 'scattergl' }
      );
      layout = { title: 'Depth vs. Percent mitochondrial genes', xaxis: { title: 'Depth' }, yaxis: { title: 'Percent mitochondrial genes' }, hovermode: "closest" };
    } else if (plot_i == 8) {
      traces.push(
        { x: this.h_data.depth.values.filter((e, i) => !this.h_discarded[i]), y: this.h_data.detected_genes.values.filter((e, i) => !this.h_discarded[i]), name: 'Kept', marker: { color: 'red' }, mode: 'markers', type: 'scattergl' },
        { x: this.h_data.depth.values.filter((e, i) => this.h_discarded[i]), y: this.h_data.detected_genes.values.filter((e, i) => this.h_discarded[i]), name: 'Discarded', marker: { color: '#CCCCCC' }, mode: 'markers', type: 'scattergl' }
      );
      layout = { title: 'Depth vs Detected genes', xaxis: { title: 'Depth' }, yaxis: { title: 'Detected genes' }, hovermode: "closest" };
    }
    
    if (traces.length > 0) {
      // Ensure layout has autosize to fit container width
      layout.autosize = true;
      layout.width = null; // Let Plotly calculate from container
      layout.height = null; // Let Plotly calculate from container
      
      Plotly.newPlot("cell_filtering_plotly_plot", traces, layout, {
        modeBarButtonsToRemove: ['sendDataToCloud'],
        displaylogo: false,
        responsive: true
      });
    }
  }

  // Action methods for event handlers
  filterInputChange() {
    this.changeCutoff(false);
  }

  disableButtonClick(event) {
    const name = event.currentTarget.id.split("-")[2];
    const btn = event.currentTarget;
    const input = document.getElementById(name + "_value");
    const saved = document.getElementById(name + "_saved");
    const row = document.getElementById('param_row_' + name);
    
    // Validate required elements
    if (!input) {
      console.error("disableButtonClick: Input element not found for", name);
      return;
    }
    if (!saved) {
      console.error("disableButtonClick: Saved element not found for", name);
      return;
    }
    
    // Check if button is currently enabled (has red styling and not disabled state)
    const isEnabled = btn.classList.contains("text-red-700") && !btn.classList.contains("bg-red-50");
    
    if (isEnabled) {
      // Disable the filter - change to disabled state with light red background
      btn.classList.remove("text-red-700", "border-red-300", "hover:bg-red-50", "hover:border-red-400", "bg-white");
      btn.classList.add("text-red-600", "bg-red-50", "border-red-200", "cursor-not-allowed", "opacity-75");
      btn.innerHTML = "Disabled";
      saved.value = input.value;
      input.value = '';
      input.disabled = true;
      input.classList.add("bg-gray-100", "cursor-not-allowed", "opacity-60");
      input.classList.remove("focus:ring-blue-500", "focus:border-blue-500");
      // Also dim the row
      if (row) {
        row.classList.add("opacity-60");
      }
    } else {
      // Enable the filter - restore to enabled state
      btn.classList.remove("text-red-600", "bg-red-50", "border-red-200", "cursor-not-allowed", "opacity-75");
      btn.classList.add("text-red-700", "border-red-300", "hover:bg-red-50", "hover:border-red-400", "bg-white");
      btn.innerHTML = "Disable";
      input.value = saved.value;
      input.disabled = false;
      input.classList.remove("bg-gray-100", "cursor-not-allowed", "opacity-60");
      input.classList.add("focus:ring-blue-500", "focus:border-blue-500");
      // Restore row opacity
      if (row) {
        row.classList.remove("opacity-60");
      }
    }
    this.changeCutoff(false);
  }

  resetFilters() {
    const disableButtons = this.element.querySelectorAll(".disabled-btn");
    disableButtons.forEach((btn) => {
      const parts = btn.id.split("-");
      const name = parts[2];
      if (!name) return;
      const input = document.getElementById(`${name}_value`);
      const saved = document.getElementById(`${name}_saved`);
      const row = document.getElementById(`param_row_${name}`);
      if (!input || !saved) return;

      btn.classList.remove("text-red-700", "border-red-300", "hover:bg-red-50", "hover:border-red-400", "bg-white");
      btn.classList.add("text-red-600", "bg-red-50", "border-red-200", "cursor-not-allowed", "opacity-75");
      btn.innerHTML = "Disabled";
      input.value = "";
      input.disabled = true;
      input.classList.add("bg-gray-100", "cursor-not-allowed", "opacity-60");
      input.classList.remove("focus:ring-blue-500", "focus:border-blue-500");
      if (row) row.classList.add("opacity-60");
    });

    this.element.querySelectorAll(".check_box_cat").forEach((checkbox) => {
      checkbox.checked = true;
    });

    const manualSelection = document.getElementById("attrs_manual_selection");
    if (manualSelection) manualSelection.value = "";
    const discardedMetadata = document.getElementById("attrs_discarded_metadata_json");
    if (discardedMetadata) discardedMetadata.value = "{}";

    this.changeCutoff(false);
  }

  plotSelectChange(event) {
    const plot_i = parseInt(event.currentTarget.value);
    this.plot(plot_i);
  }

  matrixDatasetChange() {
    this.updateInputMatrixPayload()
  }

  updateInputMatrixPayload() {
    if (!this.hasInputMatrixHiddenTarget || !this.hasMatrixDatasetSelectTarget || !this.hasParsingRunIdValue) {
      return
    }

    const datasetPath = this.matrixDatasetSelectTarget.value || "/matrix"
    if (this.hasMatrixDatasetHiddenTarget) {
      this.matrixDatasetHiddenTarget.value = datasetPath
    }
    const payload = [{
      run_id: this.parsingRunIdValue,
      output_attr_name: this.outputAttrNameValue || "output_matrix",
      output_filename: this.outputFilenameValue || "parsing/output.loom",
      output_dataset: datasetPath
    }]

    this.inputMatrixHiddenTarget.value = JSON.stringify(payload)
  }
}

