function initApiDocDataFileDropdown() {
  const swaggerRoot = document.getElementById("swagger-ui");
  if (!swaggerRoot || window.__apiDocDataFileDropdownInit) return;
  window.__apiDocDataFileDropdownInit = true;

  let pendingRefresh = null;

  function parameterRow(op, paramName) {
    if (!op) return null;
    const byDataAttr = op.querySelector(`tr[data-param-name="${paramName}"]`);
    if (byDataAttr) return byDataAttr;

    const rows = op.querySelectorAll("table.parameters tr");
    for (const row of rows) {
      const nameCell = row.querySelector(".parameter__name");
      if (!nameCell) continue;
      const label = nameCell.textContent.replace(/\s+/g, " ").trim().replace(/\s*\*\s*$/, "").trim();
      if (label === paramName) return row;
    }
    return null;
  }

  function parameterControl(row) {
    if (!row) return null;
    return row.querySelector("input, select, textarea");
  }

  function isCatalogOperation(op) {
    if (!op) return false;
    const hasProjectKey = !!parameterControl(parameterRow(op, "project_key"));
    const hasDataFile = !!parameterControl(parameterRow(op, "data_file"));
    if (!(hasProjectKey && hasDataFile)) return false;
    const pathNode = op.querySelector(".opblock-summary-path");
    return !!(pathNode && pathNode.textContent.includes("data_file_metadata_catalog"));
  }

  function catalogOperation() {
    const opblocks = swaggerRoot.querySelectorAll(".opblock");
    for (const op of opblocks) {
      if (isCatalogOperation(op)) return op;
    }
    return null;
  }

  function readProjectKey(op) {
    const control = parameterControl(parameterRow(op, "project_key"));
    return control ? control.value.trim() : "";
  }

  function fillDataFileSelect(select, paths, previousValue) {
    select.innerHTML = "";
    const placeholder = document.createElement("option");
    placeholder.value = "";
    placeholder.textContent = paths.length ? "Select a data file..." : "No data files found for this project";
    select.appendChild(placeholder);

    paths.forEach((path) => {
      const option = document.createElement("option");
      option.value = path;
      option.textContent = path;
      select.appendChild(option);
    });

    if (previousValue && paths.includes(previousValue)) {
      select.value = previousValue;
    }
  }

  function applyDataFileDropdown(op, paths) {
    const row = parameterRow(op, "data_file");
    const control = parameterControl(row);
    if (!control) return;

    if (control.tagName === "SELECT" && control.dataset.dataFileSelect === "true") {
      fillDataFileSelect(control, paths, control.value);
      return;
    }

    if (control.tagName !== "INPUT") return;

    const select = document.createElement("select");
    select.className = `${control.className} data-file-select`;
    select.dataset.dataFileSelect = "true";
    fillDataFileSelect(select, paths, control.value);
    control.replaceWith(select);
  }

  function refreshDataFileDropdown() {
    const op = catalogOperation();
    if (!op) return;
    const projectKey = readProjectKey(op);
    if (!projectKey) return;

    fetch(`/api/projects/${encodeURIComponent(projectKey)}/project_data_files`, {
      credentials: "same-origin",
      headers: { Accept: "application/json" }
    })
      .then((response) => {
        if (!response.ok) throw new Error("Failed to load data files");
        return response.json();
      })
      .then((payload) => applyDataFileDropdown(op, payload.data_files || []))
      .catch(() => applyDataFileDropdown(op, []));
  }

  function scheduleRefresh() {
    if (pendingRefresh) window.clearTimeout(pendingRefresh);
    pendingRefresh = window.setTimeout(() => {
      pendingRefresh = null;
      refreshDataFileDropdown();
    }, 120);
  }

  swaggerRoot.addEventListener("click", (event) => {
    const tryOutBtn = event.target.closest(".try-out__btn");
    if (!tryOutBtn) return;
    const op = tryOutBtn.closest(".opblock");
    if (isCatalogOperation(op)) scheduleRefresh();
  });

  swaggerRoot.addEventListener("input", (event) => {
    const op = event.target.closest(".opblock");
    if (!isCatalogOperation(op)) return;
    const row = event.target.closest("tr");
    if (!row) return;
    if (row.getAttribute("data-param-name") === "project_key") {
      scheduleRefresh();
      return;
    }
    const nameCell = row.querySelector(".parameter__name");
    if (nameCell) {
      const label = nameCell.textContent.replace(/\s+/g, " ").trim().replace(/\s*\*\s*$/, "").trim();
      if (label === "project_key") scheduleRefresh();
    }
  });

  // Fallback: when user focuses data_file input in the catalog operation, try replacing immediately.
  swaggerRoot.addEventListener("focusin", (event) => {
    const op = event.target.closest(".opblock");
    if (!isCatalogOperation(op)) return;
    const dataFileRow = parameterRow(op, "data_file");
    if (!dataFileRow || !dataFileRow.contains(event.target)) return;
    scheduleRefresh();
  });
}

window.initApiDocDataFileDropdown = initApiDocDataFileDropdown;
