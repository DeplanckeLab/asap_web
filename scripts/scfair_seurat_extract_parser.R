#!/usr/bin/env Rscript
# Parse a Seurat .rds object into the minimal extract JSON described in
# tmp/scfair_minimal_extract_spec.json. Extraction only — no compliance checks.
#
# Usage:
#   Rscript scripts/scfair_seurat_extract_parser.R path/to/object.rds
#   Rscript scripts/scfair_seurat_extract_parser.R path/to/object.rds --output tmp/extract.json
#   Rscript scripts/scfair_seurat_extract_parser.R test [path/to/object.rds]
#
# Requires: jsonlite, SeuratObject (Seurat optional)
#
# Dataset-level metadata: store scalars in object@misc$scfair_uns (see spec source_formats.seurat).

suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite")
  if (!requireNamespace("SeuratObject", quietly = TRUE)) stop("Install SeuratObject")
})

script_dir <- if (exists("script_dir")) script_dir else {
  args0 <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args0, value = TRUE)
  if (length(file_arg)) dirname(sub("^--file=", "", file_arg[1])) else getwd()
}
source(file.path(script_dir, "scfair_extract_common.R"), local = TRUE)

seurat_counts_matrix <- function(obj) {
  tryCatch(
    SeuratObject::GetAssayData(obj, assay = "RNA", layer = "counts"),
    error = function(e) {
      if ("RNA" %in% names(obj@assays)) obj@assays$RNA@counts else NULL
    }
  )
}

seurat_var_dataframe <- function(obj) {
  if (!"RNA" %in% names(obj@assays)) return(NULL)
  assay <- obj@assays$RNA
  if (inherits(assay, "Assay5")) {
    mf <- tryCatch(SeuratObject::FetchMetadata(obj, assay = "RNA"), error = function(e) NULL)
    if (is.null(mf) && !is.null(assay@meta.data)) mf <- assay@meta.data
    return(mf)
  }
  assay@meta.features
}

seurat_uns_scalars <- function(obj) {
  raw <- obj@misc[[SEURAT_UNS_SLOT]]
  if (is.null(raw) || !is.list(raw)) return(list())
  out <- list()
  for (nm in names(raw)) {
    val <- raw[[nm]]
    if (is.list(val)) next
    if (!is.atomic(val)) next
    if (length(val) != 1L) next
    out[[nm]] <- val
  }
  out
}

seurat_extensions <- function(obj) {
  raw <- obj@misc[[SEURAT_UNS_SLOT]]
  if (is.null(raw) || !is.list(raw)) return(NULL)
  extensions <- list()

  if (!is.null(raw$spatial) && is.list(raw$spatial)) {
    flat <- flatten_list_scalars(raw$spatial)
    if (length(flat) > 0L) {
      extensions$spatial <- list(
        type = "nested",
        scalars = lapply(flat, function(v) uns_scalar(v))
      )
    }
  }

  if (length(extensions) == 0L) NULL else extensions
}

parse_seurat <- function(file_path, opts = default_parser_options()) {
  if (!file.exists(file_path)) stop("File not found: ", file_path)

  obj <- readRDS(file_path)
  if (!inherits(obj, "Seurat")) stop("Not a Seurat object: ", file_path)

  counts <- seurat_counts_matrix(obj)
  n_obs <- if (!is.null(counts)) ncol(counts) else nrow(obj@meta.data)
  n_vars <- if (!is.null(counts)) nrow(counts) else NA_integer_

  meta <- obj@meta.data
  obs_cols <- colnames(meta)
  obs_series <- setNames(lapply(obs_cols, function(col) as.character(meta[[col]])), obs_cols)
  paired_obs <- build_paired_obs(obs_series, obs_cols, opts)
  obs_columns <- build_obs_columns(obs_series, obs_cols, opts, paired_obs)

  uns_scalars <- seurat_uns_scalars(obj)
  uns_keys <- names(uns_scalars)
  uns <- lapply(uns_scalars, uns_scalar)
  paired_uns <- build_paired_uns(uns_scalars)

  var_df <- seurat_var_dataframe(obj)
  var_cols <- if (!is.null(var_df)) colnames(var_df) else character()
  var_series <- list()
  if (!is.null(var_df)) {
    for (col in var_cols) {
      var_series[[col]] <- as.character(var_df[[col]])
    }
  }
  var_columns <- build_var_columns(var_series, var_cols, opts)

  var_index <- NULL
  if (!is.null(counts)) {
    series <- rownames(counts)
    if (length(series) > 0L) {
      var_index <- var_column(series)
    }
  }

  obsm_keys <- names(obj@reductions)
  obsm <- list()
  for (key in obsm_keys) {
    emb <- tryCatch(SeuratObject::Embeddings(obj, reduction = key), error = function(e) NULL)
    if (!is.null(emb) && length(dim(emb)) == 2L) {
      obsm[[key]] <- array_meta(
        dim(emb),
        "double",
        any(is.infinite(emb)),
        any(is.nan(emb))
      )
    }
  }

  list(
    source_url = normalizePath(file_path, mustWork = TRUE),
    format = "seurat",
    file_inventory = list(
      matrix = list(n_obs = n_obs, n_vars = n_vars),
      obs = list(column_names = obs_cols),
      var = list(column_names = var_cols),
      uns = list(top_level_keys = uns_keys),
      obsm = list(keys = obsm_keys)
    ),
    uns = uns,
    paired_fields = list(obs = paired_obs, uns = paired_uns),
    obs = list(columns = obs_columns),
    var = c(
      if (!is.null(var_index)) list(index = var_index) else list(),
      list(columns = var_columns)
    ),
    extensions = seurat_extensions(obj),
    obsm = if (length(obsm) > 0L) obsm else NULL
  )
}

parse_file <- function(file_path, opts = default_parser_options()) {
  ext <- tolower(tools::file_ext(file_path))
  if (!ext %in% c("rds", "rda")) stop("Unsupported extension: ", ext, " (expected .rds)")
  assemble_extract(parse_seurat(file_path, opts))
}

run_self_tests <- function(fixture_path = NULL) {
  cat("Running scfair_seurat_extract_parser self-tests...\n")
  errors <- character()
  assert <- function(cond, msg) if (!isTRUE(cond)) errors <<- c(errors, msg)

  fixture <- fixture_path
  if (!is.null(fixture) && file.exists(fixture)) {
    ex <- parse_file(fixture)
    assert(ex$format == "seurat", "detects seurat format")
    assert(length(ex$obs$columns) > 0L, "reads obs columns")
    assert(is.null(ex$missing_for_full_compliance), "extract must not include compliance diagnostics")
  } else {
    cat("Skipping file parse tests (no Seurat .rds fixture)\n")
  }

  assert(!is.null(uns_scalar("x")$type), "uns_scalar helper")

  if (length(errors) > 0L) {
    cat(paste("FAILED:", errors), sep = "\n  ")
    quit(status = 1)
  }
  cat("All self-tests passed.\n")
  invisible(TRUE)
}

main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) > 0L && args[[1]] == "test") {
    fixture <- if (length(args) >= 2L) args[[2]] else NULL
    run_self_tests(fixture)
    return(invisible(NULL))
  }

  if (length(args) < 1L) {
    stop("Usage: Rscript scfair_seurat_extract_parser.R <file.rds> [--output path.json]")
  }

  input_path <- args[[1]]
  output <- sub("\\.rds$", "_extract.json", input_path, ignore.case = TRUE)
  if (length(args) >= 3L && args[[2]] == "--output") output <- args[[3]]

  extract <- parse_file(input_path)
  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(extract, output, auto_unbox = TRUE, pretty = TRUE)
  cat(sprintf("Wrote %s\n", output))
}

if (identical(sys.nframe(), 0L)) main()
