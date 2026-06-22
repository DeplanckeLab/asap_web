#!/usr/bin/env Rscript
# Parse a Loom or H5AD file into the minimal extract JSON described in
# tmp/scfair_minimal_extract_spec.json. Extraction only — no compliance checks.
#
# Usage:
#   Rscript scripts/scfair_loom_h5ad_extract_parser.R path/to/file.h5ad
#   Rscript scripts/scfair_loom_h5ad_extract_parser.R path/to/file.loom --output tmp/extract.json
#   Rscript scripts/scfair_loom_h5ad_extract_parser.R test [path/to/fixture.h5ad]
#
# Requires: jsonlite, rhdf5

suppressPackageStartupMessages({
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Install jsonlite")
  if (!requireNamespace("rhdf5", quietly = TRUE)) stop("Install rhdf5")
})

script_dir <- if (exists("script_dir")) script_dir else {
  args0 <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args0, value = TRUE)
  if (length(file_arg)) dirname(sub("^--file=", "", file_arg[1])) else getwd()
}
source(file.path(script_dir, "scfair_extract_common.R"), local = TRUE)

h5_exists <- function(file, path) {
  path <- paste0("/", sub("^/+", "", path))
  info <- rhdf5::h5ls(file)
  any(info$group == path) || any(paste(info$group, info$name, sep = "/") == path)
}

h5_path_parts <- function(path) {
  path <- sub("^/+", "", path)
  parts <- strsplit(path, "/", fixed = TRUE)[[1]]
  group <- if (length(parts) > 1L) paste("/", paste(parts[-length(parts)], collapse = "/"), sep = "") else "/"
  list(group = group, name = parts[length(parts)])
}

# -----------------------------------------------------------------------------
# H5AD low-level readers
# -----------------------------------------------------------------------------

h5_attr_string <- function(x) {
  if (is.raw(x)) rawToChar(x)
  else as.character(x)
}

h5_group_encoding <- function(file, path) {
  if (!h5_exists(file, path)) return(NA_character_)
  attrs <- rhdf5::h5readAttributes(file, path)
  enc <- attrs[["encoding-type"]]
  if (is.null(enc)) return(NA_character_)
  h5_attr_string(enc)
}

read_h5_dataset_scalar <- function(file, path) {
  if (!h5_exists(file, path)) return(NA_character_)
  info <- rhdf5::h5ls(file)
  parts <- h5_path_parts(path)
  row <- info[info$group == parts$group & info$name == parts$name, , drop = FALSE]
  if (nrow(row) == 0L || row$otype[[1]] != "H5I_DATASET") return(NA_character_)
  val <- rhdf5::h5read(file, sub("^/+", "", path))
  if (is.raw(val)) return(h5_attr_string(val))
  if (length(val) == 1L) return(as.character(val))
  NA_character_
}

read_h5_string_series <- function(file, path, n_rows = NULL) {
  if (!h5_exists(file, path)) return(character())

  info <- rhdf5::h5ls(file)
  parts <- h5_path_parts(path)
  row <- info[info$group == parts$group & info$name == parts$name, , drop = FALSE]

  read_vector <- function(raw) {
    if (is.raw(raw)) return(h5_attr_string(raw))
    if (is.vector(raw) || is.array(raw)) {
      vals <- as.character(raw)
      if (!is.null(n_rows)) vals <- vals[seq_len(min(length(vals), n_rows))]
      return(vals)
    }
    character()
  }

  if (nrow(row) > 0L && row$otype[[1]] == "H5I_DATASET") {
    return(read_vector(rhdf5::h5read(file, sub("^/+", "", path))))
  }

  enc <- h5_group_encoding(file, path)
  if (!is.na(enc) && enc %in% c("categorical", "nullable-categorical")) {
    cats <- read_h5_string_series(file, file.path(path, "categories"))
    codes <- as.integer(rhdf5::h5read(file, sub("^/+", "", file.path(path, "codes"))))
    vals <- ifelse(codes < 0L | is.na(codes), NA_character_, cats[codes + 1L])
    return(as.character(vals))
  }

  if (!is.na(enc) && enc %in% c("string-array", "ascii", "string", "nullable-string-array")) {
    items <- read_h5_string_series(file, file.path(path, "values"))
    if (enc == "nullable-string-array" && h5_exists(file, file.path(path, "mask"))) {
      mask <- as.logical(rhdf5::h5read(file, sub("^/+", "", file.path(path, "mask"))))
      items[mask] <- NA_character_
    }
    return(as.character(items))
  }

  character()
}

list_group_columns <- function(file, group_path) {
  group_path <- paste0("/", sub("^/+", "", group_path))
  if (!h5_exists(file, group_path)) return(character())
  info <- rhdf5::h5ls(file)
  children <- info[info$group == group_path & info$name != "", "name", drop = TRUE]
  children <- children[!children %in% c("_index", "index", "__categories")]
  sort(unique(children))
}

read_matrix_dims_h5ad <- function(file) {
  n_obs <- NA_integer_
  n_vars <- NA_integer_
  if (!h5_exists(file, "X")) return(list(n_obs = n_obs, n_vars = n_vars))

  attrs <- rhdf5::h5readAttributes(file, "X")
  if (!is.null(attrs$shape)) {
    sh <- as.integer(attrs$shape)
    if (length(sh) >= 2L) return(list(n_obs = sh[1], n_vars = sh[2]))
  }

  info <- rhdf5::h5ls(file)
  row <- info[info$group == "/" & info$name == "X", , drop = FALSE]
  if (nrow(row) > 0L && row$otype[[1]] == "H5I_DATASET") {
    d <- rhdf5::h5dump(file, readOnly = TRUE)$X
    if (!is.null(d$dim)) {
      sh <- as.integer(d$dim)
      if (length(sh) >= 2L) return(list(n_obs = sh[1], n_vars = sh[2]))
    }
  }
  list(n_obs = n_obs, n_vars = n_vars)
}

read_obsm_keys <- function(file) {
  if (!h5_exists(file, "obsm")) return(character())
  list_group_columns(file, "obsm")
}

read_obsm_array_meta <- function(file, key, n_obs) {
  path <- file.path("obsm", key)
  if (!h5_exists(file, path)) return(NULL)

  enc <- h5_group_encoding(file, path)
  if (!is.na(enc) && enc %in% c("array", "dense_array") && h5_exists(file, file.path(path, "data"))) {
    d <- rhdf5::h5read(file, file.path(path, "data"))
    sh <- dim(d)
    return(array_meta(sh, as.character(typeof(d)), any(is.infinite(d)), any(is.nan(d))))
  }

  if (h5_exists(file, path)) {
    info <- rhdf5::h5ls(file)
    row <- info[info$group == "/obsm" & info$name == key, , drop = FALSE]
    if (nrow(row) > 0L && row$otype[[1]] == "H5I_DATASET") {
      d <- rhdf5::h5read(file, path)
      return(array_meta(dim(d), as.character(typeof(d)), any(is.infinite(d)), any(is.nan(d))))
    }
  }
  NULL
}

read_h5_leaf_value <- function(file, path) {
  path <- sub("^/+", "", path)
  if (!h5_exists(file, path)) return(NULL)
  val <- rhdf5::h5read(file, path)
  if (is.raw(val)) return(h5_attr_string(val))
  if (length(val) != 1L) return(NULL)
  val
}

flatten_uns_paths <- function(file, prefix = "uns") {
  prefix_norm <- sub("^/+", "", prefix)
  if (!h5_exists(file, prefix_norm)) return(list())
  info <- rhdf5::h5ls(file)
  pattern <- paste0("^/?", gsub("/", "\\\\/", prefix_norm), "(/|$)")
  datasets <- info[grepl(pattern, info$group) & info$otype == "H5I_DATASET", ]
  out <- list()
  for (i in seq_len(nrow(datasets))) {
    rel <- paste(datasets$group[i], datasets$name[i], sep = "/")
    rel <- sub("^/+", "", rel)
    rel <- sub(paste0("^", prefix_norm, "/?"), "", rel)
    if (!nzchar(rel)) next
    val <- read_h5_leaf_value(file, file.path(prefix_norm, rel))
    if (!is.null(val)) out[[rel]] <- val
  }
  out
}

parse_h5ls_dim <- function(dimstr) {
  if (is.na(dimstr) || !nzchar(dimstr) || !grepl(" x ", dimstr, fixed = TRUE)) return(integer())
  as.integer(strsplit(trimws(dimstr), " x ", fixed = TRUE)[[1]])
}

build_spatial_extension_h5ad <- function(file_path) {
  prefix_norm <- "uns/spatial"
  if (!h5_exists(file_path, prefix_norm)) return(NULL)
  info <- rhdf5::h5ls(file_path)
  rows <- info[grepl("^/uns/spatial(/|$)", info$group) & info$otype == "H5I_DATASET", ]
  scalars <- list()
  arrays <- list()
  for (i in seq_len(nrow(rows))) {
    rel <- sub("^/uns/spatial/?", "", paste(rows$group[i], rows$name[i], sep = "/"))
    if (!nzchar(rel)) next
    parts <- parse_h5ls_dim(rows$dim[i])
    if (length(parts) > 0L) {
      if (length(parts) == 3L) parts <- rev(parts)
      dtype <- if ("dclass" %in% names(rows)) rows$dclass[i] else "unknown"
      arrays[[rel]] <- array_meta(parts, as.character(dtype), FALSE, FALSE)
      next
    }
    val <- read_h5_leaf_value(file_path, file.path(prefix_norm, rel))
    if (!is.null(val)) scalars[[rel]] <- uns_scalar(val)
  }
  if (length(scalars) == 0L && length(arrays) == 0L) return(NULL)
  out <- list(type = "nested")
  if (length(scalars) > 0L) out$scalars <- scalars
  if (length(arrays) > 0L) out$arrays <- arrays
  out
}

# -----------------------------------------------------------------------------
# H5AD parser
# -----------------------------------------------------------------------------

parse_h5ad <- function(file_path, opts = default_parser_options()) {
  if (!file.exists(file_path)) stop("File not found: ", file_path)

  obs_cols <- list_group_columns(file_path, "obs")
  var_cols <- list_group_columns(file_path, "var")
  uns_keys <- if (h5_exists(file_path, "uns")) list_group_columns(file_path, "uns") else character()

  dims <- read_matrix_dims_h5ad(file_path)
  n_obs <- dims$n_obs
  n_vars <- dims$n_vars

  obs_series <- list()
  for (col in obs_cols) {
    series <- read_h5_string_series(file_path, file.path("obs", col))
    if (length(series) > 0L) obs_series[[col]] <- series
  }
  paired_obs <- build_paired_obs(obs_series, obs_cols, opts)
  obs_columns <- build_obs_columns(obs_series, obs_cols, opts, paired_obs)

  uns <- list()
  for (key in uns_keys) {
    val <- read_h5_dataset_scalar(file_path, file.path("uns", key))
    if (!is.na(val)) uns[[key]] <- uns_scalar(val)
  }

  uns_scalars <- setNames(lapply(uns, function(u) u$value), names(uns))
  paired_uns <- build_paired_uns(uns_scalars)

  var_columns <- list()
  var_series <- list()
  for (col in var_cols) {
    series <- read_h5_string_series(file_path, file.path("var", col))
    if (length(series) > 0L) var_series[[col]] <- series
  }
  var_columns <- build_var_columns(var_series, var_cols, opts)

  var_index <- NULL
  for (idx_key in c("_index", "index")) {
    if (!h5_exists(file_path, file.path("var", idx_key))) next
    series <- read_h5_string_series(file_path, file.path("var", idx_key))
    if (length(series) == 0L) next
    var_index <- var_column(series)
    break
  }

  obsm_keys <- read_obsm_keys(file_path)
  obsm <- list()
  for (key in obsm_keys) {
    meta <- read_obsm_array_meta(file_path, key, n_obs)
    if (!is.null(meta)) obsm[[key]] <- meta
  }

  extensions <- list()
  spatial <- build_spatial_extension_h5ad(file_path)
  if (!is.null(spatial)) extensions$spatial <- spatial

  list(
    source_url = normalizePath(file_path, mustWork = TRUE),
    format = "h5ad",
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
    extensions = if (length(extensions) > 0L) extensions else NULL,
    obsm = if (length(obsm) > 0L) obsm else NULL
  )
}

# -----------------------------------------------------------------------------
# Loom parser (HDF5 layout: /col_attrs, /row_attrs, /attrs)
# -----------------------------------------------------------------------------

parse_loom <- function(file_path, opts = default_parser_options()) {
  if (!file.exists(file_path)) stop("File not found: ", file_path)

  info <- rhdf5::h5ls(file_path)
  col_attrs <- sort(unique(info$name[info$group == "/col_attrs"]))
  row_attrs <- sort(unique(info$name[info$group == "/row_attrs"]))
  global_attrs <- sort(unique(info$name[info$group == "/attrs"]))

  n_obs <- NA_integer_
  n_vars <- NA_integer_
  matrix_row <- info[info$group == "/matrix" & info$otype == "H5I_DATASET", , drop = FALSE]
  if (nrow(matrix_row) > 0L) {
    d <- tryCatch(rhdf5::h5read(file_path, "/matrix"), error = function(e) NULL)
    if (!is.null(d) && !is.null(dim(d))) {
      n_vars <- dim(d)[1]
      n_obs <- dim(d)[2]
    }
  }

  obs_series <- list()
  for (col in col_attrs) {
    series <- read_h5_string_series(file_path, file.path("/col_attrs", col))
    if (length(series) > 0L) obs_series[[col]] <- series
  }
  paired_obs <- build_paired_obs(obs_series, col_attrs, opts)
  obs_columns <- build_obs_columns(obs_series, col_attrs, opts, paired_obs)

  uns <- list()
  for (key in global_attrs) {
    val <- read_h5_dataset_scalar(file_path, file.path("/attrs", key))
    if (!is.na(val)) uns[[key]] <- uns_scalar(val)
  }

  uns_scalars <- setNames(lapply(uns, function(u) u$value), names(uns))
  paired_uns <- build_paired_uns(uns_scalars)

  var_series <- list()
  for (col in row_attrs) {
    series <- read_h5_string_series(file_path, file.path("/row_attrs", col))
    if (length(series) > 0L) var_series[[col]] <- series
  }
  var_columns <- build_var_columns(var_series, row_attrs, opts)

  var_index <- NULL
  for (idx_key in c("feature_id", "index", "_index")) {
    if (!idx_key %in% row_attrs) next
    series <- read_h5_string_series(file_path, file.path("/row_attrs", idx_key))
    if (length(series) == 0L) next
    var_index <- var_column(series)
    break
  }

  list(
    source_url = normalizePath(file_path, mustWork = TRUE),
    format = "loom",
    file_inventory = list(
      matrix = list(n_obs = n_obs, n_vars = n_vars),
      obs = list(column_names = col_attrs),
      var = list(column_names = row_attrs),
      uns = list(top_level_keys = global_attrs),
      obsm = list(keys = character())
    ),
    uns = uns,
    paired_fields = list(obs = paired_obs, uns = paired_uns),
    obs = list(columns = obs_columns),
    var = c(
      if (!is.null(var_index)) list(index = var_index) else list(),
      list(columns = var_columns)
    ),
    extensions = NULL,
    obsm = NULL
  )
}

# -----------------------------------------------------------------------------
# Assemble final document
# -----------------------------------------------------------------------------

parse_file <- function(file_path, opts = default_parser_options()) {
  ext <- tolower(tools::file_ext(file_path))
  parsed <- switch(
    ext,
    h5ad = parse_h5ad(file_path, opts),
    loom = parse_loom(file_path, opts),
    stop("Unsupported extension: ", ext, " (expected .h5ad or .loom)")
  )

  extract <- assemble_extract(parsed)
  extract
}

# -----------------------------------------------------------------------------
# Self-tests
# -----------------------------------------------------------------------------

run_self_tests <- function(fixture_path = NULL) {
  cat("Running scfair_loom_h5ad_extract_parser self-tests...\n")
  errors <- character()
  assert <- function(cond, msg) if (!isTRUE(cond)) errors <<- c(errors, msg)

  fixture <- fixture_path %||% "/data/asap2_test/tmp/cxg_example.h5ad"
  if (!file.exists(fixture)) fixture <- "tmp/cxg_example.h5ad"
  if (!file.exists(fixture)) {
    cat("Skipping file parse tests (fixture not found):", fixture, "\n")
  } else {
    ex <- parse_file(fixture)
    assert(ex$format == "h5ad", "detects h5ad format")
    assert(!is.null(ex$paired_fields$obs$assay_ontology_term_id$pairs[[1]]$id), "structured paired_fields")
    assert(ex$file_inventory$matrix$n_obs > 0L, "reads n_obs")
    assert(length(ex$obs$columns) > 0L, "reads obs columns")
    assert(is.null(ex$missing_for_full_compliance), "extract must not include compliance diagnostics")
  }

  assert(!is.null(uns_scalar("x")$type), "uns_scalar helper")
  assert(!is.null(paired_block("a", list(list(id = "1", label = "2")))$pairs), "paired_block helper")

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
    stop("Usage: Rscript scfair_loom_h5ad_extract_parser.R <file.h5ad|file.loom> [--output path.json]")
  }

  input_path <- args[[1]]
  output <- sub("\\.(h5ad|loom)$", "_extract.json", input_path, ignore.case = TRUE)
  if (length(args) >= 3L && args[[2]] == "--output") output <- args[[3]]

  extract <- parse_file(input_path)
  dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(extract, output, auto_unbox = TRUE, pretty = TRUE)
  cat(sprintf("Wrote %s\n", output))
}

if (identical(sys.nframe(), 0L)) main()
