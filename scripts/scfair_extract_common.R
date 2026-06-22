# Shared helpers for scFAIR minimal extract parsers (H5AD, Loom, Seurat).
# Sourced by scfair_loom_h5ad_extract_parser.R and scfair_seurat_extract_parser.R.

SPEC_FILE <- "scfair_minimal_extract_spec.json"

# ID -> label column pairs for paired_fields.obs (must match paired_field_definitions.obs in SPEC_FILE).
LABEL_PAIRS_OBS <- c(
  "assay_ontology_term_id" = "assay",
  "cell_type_ontology_term_id" = "cell_type",
  "development_stage_ontology_term_id" = "development_stage",
  "disease_ontology_term_id" = "disease",
  "self_reported_ethnicity_ontology_term_id" = "self_reported_ethnicity",
  "sex_ontology_term_id" = "sex",
  "tissue_ontology_term_id" = "tissue"
)

# scFAIR schema 7.1.0 obs/var column names (core + spatial + perturb). Must match
# schema_fields in scfair_minimal_extract_spec.json.
SCHEMA_OBS_FIELDS <- c(
  "assay_ontology_term_id", "assay",
  "tissue_type",
  "tissue_ontology_term_id", "tissue",
  "cell_type_ontology_term_id", "cell_type",
  "development_stage_ontology_term_id", "development_stage",
  "sex_ontology_term_id", "sex",
  "self_reported_ethnicity_ontology_term_id", "self_reported_ethnicity",
  "strain_or_genetic_background_term_id", "strain_or_genetic_background",
  "disease_ontology_term_id", "disease",
  "experimental_condition_ontology_term_id", "experimental_condition",
  "perturbation_types",
  "donor_id",
  "is_primary_data",
  "suspension_type",
  "array_row", "array_col", "in_tissue",
  "genetic_perturbation_id", "genetic_perturbation_strategy"
)

SCHEMA_VAR_FIELDS <- c(
  "feature_is_filtered",
  "feature_biotype",
  "feature_length",
  "feature_name",
  "feature_reference",
  "feature_type",
  "feature_chromosome"
)

SEURAT_UNS_SLOT <- "scfair_uns"

default_parser_options <- function() {
  list(
    max_distinct = 200L
  )
}

uns_scalar <- function(value, type = NULL) {
  if (is.null(type)) {
    type <- if (is.logical(value)) "boolean"
    else if (is.integer(value) || (is.numeric(value) && length(value) == 1L && value == as.integer(value))) "integer"
    else "string"
  }
  list(type = type, value = if (type == "string") as.character(value) else value)
}

obs_column <- function(distinct_values) {
  list(distinct_values = as.character(distinct_values))
}

var_column <- function(per_feature_values) {
  list(per_feature_values = as.character(per_feature_values))
}

paired_block <- function(label_field, pairs) {
  list(
    label_field = label_field,
    pairs = lapply(pairs, function(p) list(id = p$id, label = p$label))
  )
}

array_meta <- function(shape, dtype, has_inf = FALSE, has_nan = FALSE) {
  list(
    type = "array",
    shape = as.integer(shape),
    dtype = dtype,
    has_inf = isTRUE(has_inf),
    has_nan = isTRUE(has_nan)
  )
}

truncate_unique <- function(values, max_n) {
  unique(as.character(values[!is.na(values) & values != ""]))[seq_len(min(length(unique(values)), max_n))]
}

store_obs_label_pairs <- function(obs_series, id_field, label_field, max_pairs = 200L) {
  ids <- obs_series[[id_field]]
  labels <- obs_series[[label_field]]
  if (is.null(ids) || is.null(labels) || length(ids) != length(labels)) return(NULL)

  pairs <- list()
  seen <- character()
  for (i in seq_along(ids)) {
    id_val <- ids[[i]]
    label_val <- labels[[i]]
    if (is.na(id_val) || is.na(label_val) || !nzchar(id_val) || !nzchar(label_val)) next
    token <- paste(id_val, label_val, sep = " || ")
    if (token %in% seen) next
    seen <- c(seen, token)
    pairs[[length(pairs) + 1L]] <- list(id = id_val, label = label_val)
    if (length(pairs) >= max_pairs) break
  }
  if (length(pairs) == 0L) return(NULL)
  paired_block(label_field, pairs)
}

paired_obs_column_names <- function(paired_obs) {
  if (length(paired_obs) == 0L) return(character())
  unlist(lapply(names(paired_obs), function(id_field) {
    c(id_field, paired_obs[[id_field]]$label_field)
  }), use.names = FALSE)
}

build_obs_columns <- function(obs_series, obs_cols, opts, paired_obs = NULL) {
  skip <- paired_obs_column_names(paired_obs)
  obs_columns <- list()
  for (col in obs_cols) {
    if (col %in% skip) next
    if (!col %in% SCHEMA_OBS_FIELDS) next
    series <- obs_series[[col]]
    if (length(series) == 0L) next
    distinct <- truncate_unique(series, opts$max_distinct)
    obs_columns[[col]] <- obs_column(distinct)
  }
  obs_columns
}

build_var_columns <- function(var_series, var_cols, opts) {
  var_columns <- list()
  for (col in var_cols) {
    if (!col %in% SCHEMA_VAR_FIELDS) next
    series <- var_series[[col]]
    if (is.null(series) || length(series) == 0L) next
    var_columns[[col]] <- var_column(series)
  }
  var_columns
}

build_paired_obs <- function(obs_series, obs_cols, opts) {
  paired_obs <- list()
  for (id_field in names(LABEL_PAIRS_OBS)) {
    label_field <- LABEL_PAIRS_OBS[[id_field]]
    if (!id_field %in% obs_cols || !label_field %in% obs_cols) next
    block <- store_obs_label_pairs(obs_series, id_field, label_field, opts$max_distinct)
    if (!is.null(block)) paired_obs[[id_field]] <- block
  }
  paired_obs
}

build_paired_uns <- function(uns_scalars) {
  # organism pair must match paired_field_definitions.uns in SPEC_FILE.
  paired_uns <- list()
  if ("organism_ontology_term_id" %in% names(uns_scalars) && "organism" %in% names(uns_scalars)) {
    paired_uns$organism_ontology_term_id <- paired_block(
      "organism",
      list(list(
        id = as.character(uns_scalars$organism_ontology_term_id),
        label = as.character(uns_scalars$organism)
      ))
    )
  }
  paired_uns
}

flatten_list_scalars <- function(x, prefix = character()) {
  if (is.null(x)) return(list())
  if (is.atomic(x) && length(x) == 1L) {
    key <- paste(prefix, collapse = "/")
    return(setNames(list(x), key))
  }
  if (!is.list(x)) return(list())
  out <- list()
  for (nm in names(x)) {
    out <- c(out, flatten_list_scalars(x[[nm]], c(prefix, nm)))
  }
  out
}

assemble_extract <- function(parsed) {
  c(
    list(
      specification = SPEC_FILE,
      source_url = parsed$source_url,
      format = parsed$format,
      extracted_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    ),
    parsed[setdiff(names(parsed), c("source_url", "format"))]
  )
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
