# StdMethod: `attrs_json` and `command_json` Reference

Both `attrs_json` and `command_json` are text columns on the `std_methods` database table (default `"{}"`). They store JSON objects that configure, respectively, the **form/UI parameters** a user fills in before running a method, and the **CLI command** that gets executed inside a Docker container.

At runtime, these are **merged with their Step-level counterparts**: `Step#method_attrs_json` fills in missing attribute sub-keys, and `Step#command_json` provides base command entries that the std_method can override.

---

## Table of Contents

1. [attrs_json](#1-attrs_json)
   - [Structure overview](#11-structure-overview)
   - [Merge logic](#12-merge-logic-with-stepmethod_attrs_json)
   - [Per-attribute option reference](#13-per-attribute-option-reference)
   - [Constraints sub-object](#14-constraints-sub-object)
   - [run_display sub-object](#15-run_display-sub-object)
2. [command_json](#2-command_json)
   - [Structure overview](#21-structure-overview)
   - [Merge logic](#22-merge-logic-with-stepcommand_json)
   - [Top-level key reference](#23-top-level-key-reference)
   - [opts / args entry reference](#24-opts--args-entry-reference)
   - [db_json sub-object](#25-db_json-sub-object)
   - [Legacy top-level DE keys](#26-legacy-top-level-de-keys)
   - [Final Run command_json](#27-final-run-command_json-output-of-set_run)
3. [Related JSON columns](#3-related-json-columns-on-stdmethod)
4. [Concrete example](#4-concrete-example)
5. [Key source files](#5-key-source-files)

---

## 1. `attrs_json`

### 1.1 Structure overview

A JSON **object** whose top-level keys are **parameter names** (e.g. `input_matrix`, `groups`, `fdr`, `nber_dims`). Each value is a **nested object** of UI/runtime options describing how the parameter should be rendered and validated.

```json
{
  "input_matrix": {
    "label": "Expression matrix",
    "widget": "input_data",
    "valid_types": [["float_matrix", "int_matrix"]],
    "source_steps": ["normalization", "cell_filtering"],
    "req_data_structure": "array",
    "min_nber_items": 1,
    "max_nber_items": 1
  },
  "fdr": {
    "label": "FDR threshold",
    "widget": "textfield",
    "default": "0.05",
    "min_val": 0,
    "max_val": 1,
    "not_null": true
  }
}
```

#### Method-based source filtering

To restrict which upstream methods' output is accepted as input, use `source_methods` (whitelist) or `excluded_source_methods` (blacklist) alongside `source_steps`. Both are objects keyed by step name, with arrays of std_method names as values.

**Whitelist example** (PCA accepts normalization output only from SCT):
```json
{
  "input_matrix": {
    "widget": "input_data",
    "source_steps": ["scaling", "normalization"],
    "source_methods": { "normalization": ["seurat_sct"] },
    "valid_types": [["dataset"], ["num_matrix", "int_matrix"]]
  }
}
```

**Blacklist example** (Scaling rejects normalization output from SCT):
```json
{
  "input_matrix": {
    "widget": "input_data",
    "source_steps": ["removing_covariates", "normalization"],
    "excluded_source_methods": { "normalization": ["seurat_sct"] },
    "valid_types": [["dataset"], ["num_matrix", "int_matrix"]]
  }
}
```

Rules:
- Only steps listed in `source_steps` can be filtered by `source_methods` or `excluded_source_methods`.
- Steps not mentioned in either filter object accept output from all their methods (default behavior).
- `source_methods` and `excluded_source_methods` can coexist on the same attribute but should not reference the same step (whitelist takes precedence if both match).
- The filter is applied at three levels: the input dropdown (form), method availability (grayed-out methods), and step lock/unlock (pipeline panel).

### 1.2 Merge logic with `Step#method_attrs_json`

`Basic.get_std_method_attrs(std_method, step)` in `lib/basic.rb` (line ~2509) merges:

1. Starts with `std_method.attrs_json` (parsed).
2. Iterates over `step.method_attrs_json` keys.
3. For each parameter name that is missing or incomplete in the std_method attrs, **copies sub-keys from the step level** -- but only if the sub-key does not already exist on the std_method side.

This means the std_method can override specific sub-keys (e.g. `default`, `label`) while inheriting the rest from the step. Many std_methods have `attrs_json: "{}"` and rely entirely on the step's `method_attrs_json`.

### 1.3 Per-attribute option reference

| Key | Type | Widget(s) | Description | Handled in |
|-----|------|-----------|-------------|------------|
| `label` | string | all | Display label in the form and in run badges. Falls back to `attr_name.humanize`. | `_attributes.html.erb`, `reqs_controller.rb`, `application_helper.rb` |
| `description` | string | all | Help text shown as a `?` tooltip next to the label, or as small text below `textfield`/`select`/`checkbox`. | `_attributes.html.erb` |
| `widget` | string | -- | Determines the form input type. One of: `"input_data"`, `"textfield"`, `"hidden"`, `"checkbox"`, `"select"`, `"input_gene_set_item"`. Attributes with no widget or `obsolete: true` are skipped. | `_attributes.html.erb` |
| `default` | any | all | Default value used when the user has not set a value. Also used by `application_helper.rb` to hide run badges when the run value matches the default. For `checkbox`, `false` means unchecked. | `_attributes.html.erb`, `basic.rb` (set_run args/opts resolution), `application_helper.rb` |
| `default_expression` | string | textfield | A JavaScript expression evaluated client-side to compute the default dynamically. When present, the server-side `default` is not pre-filled; instead, JS populates the field. Emitted as `data-attr-default-expression` on the form container. | `_attributes.html.erb` (data attribute), JS client-side |
| `valid_types` | array of arrays | input_data | Nested OR-groups of data class names (e.g. `[["float_matrix", "int_matrix"]]`). Each inner array is an OR group; all outer entries must be satisfied. Used to filter `Annot` candidates that match. | `_attributes.html.erb`, `reqs_controller.rb`, `basic.rb` |
| `source_steps` | array of strings | input_data | Step names (e.g. `["normalization", "cell_filtering"]`) whose output datasets are eligible for this input. | `_attributes.html.erb`, `projects_controller.rb` |
| `source_methods` | object | input_data | Per-step whitelist of std_method names whose output is accepted. Keys are step names from `source_steps`, values are arrays of method names. E.g. `{"normalization": ["seurat_sct"]}` means only SCT output from normalization is accepted (other source_steps are unfiltered). | `_attributes.html.erb`, `projects_controller.rb` |
| `excluded_source_methods` | object | input_data | Per-step blacklist of std_method names whose output is excluded. Keys are step names from `source_steps`, values are arrays of method names. E.g. `{"normalization": ["seurat_sct"]}` means SCT output from normalization is rejected (all other methods are accepted). | `_attributes.html.erb`, `projects_controller.rb` |
| `req_data_structure` | string | input_data | `"array"` allows multi-select (multiple datasets). Otherwise single-select. | `_attributes.html.erb`, `basic.rb` |
| `combinatorial_runs` | boolean | input_data | When `true` and the user selects multiple items, the system creates **one run per combination** instead of passing all items to a single run. | `reqs_controller.rb` (line ~123), `basic.rb` |
| `min_nber_items` | integer | input_data | Minimum number of items the user must select. **`0` = optional** (does not gate method availability). **`>= 1` = required** (shows "required" badge, enforced client-side, and required for method availability). Primary signal for required vs optional on `input_data`. Rendered as a constraint badge when not an exact min/max pair. | `_attributes.html.erb`, `FormAttrConstraints`, `projects_controller.rb` |
| `max_nber_items` | integer | input_data | Maximum number of items. When `1`, forces single-select even if `req_data_structure` is `array`. | `_attributes.html.erb` |
| `dataset_field` | string | input_data | The field from the selected dataset hash used as the CLI variable value. Default is `"output_attr_name"`. | `basic.rb` (set_run, line ~3503) |
| `set_h_var_to_annot_id` | boolean | input_data | When `true`, `set_run` stores the selected annotation's database ID in `h_var[attr_name]` instead of the dataset field string. Used when the CLI needs numeric annot IDs. Do not combine with `use_annot_id` on the same `param_key` in `command_json`. | `basic.rb` (line ~3532) |
| `dropdown_placeholder` | string | input_data | Custom text for the closed dropdown button instead of the default `"-- Select <label> --"`. | `_attributes.html.erb` (line ~176) |
| `placeholder` | string | input_data, textfield | Placeholder text for the input. For `input_data`, used as a fallback when `dropdown_placeholder` is absent. | `_attributes.html.erb` |
| `not_null` | boolean | all | **Scalars** (`textfield`, `select`, `checkbox`, ...): marks the field as required. Renders a "required" badge and is enforced client-side. For `select`, prevents the empty/null option from appearing. Do **not** use on `input_data` -- use `min_nber_items` instead. | `_attributes.html.erb`, `FormAttrConstraints` |
| `optional` | boolean | input_data, textfield | **Deprecated.** Legacy flag; still read for backward compatibility. Use `min_nber_items: 0` (optional) or `>= 1` (required) on `input_data`, and `not_null` on scalars. Migrate with `rake reference_data:migrate_optional_to_not_null`. | `FormAttrConstraints` (legacy read only) |
| `min_val` | numeric | textfield, select | Minimum allowed value. For `select` with both `min_val` and `max_val`, generates the option list as a range. For `textfield`, emitted as `data-attr-min-val` for client-side validation and shown as a constraint badge. | `_attributes.html.erb` |
| `max_val` | numeric | textfield, select | Maximum allowed value. Same behavior as `min_val`. | `_attributes.html.erb` |
| `min_val_expression` | string | textfield | JavaScript expression for a dynamic minimum (evaluated client-side). When present, static `min_val` badges are suppressed. Emitted as `data-attr-min-val-expression`. | `_attributes.html.erb` |
| `max_val_expression` | string | textfield | JavaScript expression for a dynamic maximum. Same as above. | `_attributes.html.erb` |
| `list` | array | select | Explicit list of `[label, value]` pairs for the select options. Used when `min_val`/`max_val` are not set. | `_attributes.html.erb` (line ~300) |
| `null_name` | string | select | Label for the empty/none option at the top of a select (default `"None"`). Only shown when `not_null` is falsy. | `_attributes.html.erb` (line ~303) |
| `constraints` | object | all | Validation and visibility constraints. Supports `required_if` and `visible_if`. See section 1.4. Emitted as `data-attr-constraints` for JS. | `_attributes.html.erb`, `reqs_controller.rb`, `form_req_controller.js` |
| `run_display` | object | all | Controls how run parameters appear in badges / run summaries (not the form). See section 1.5. | `application_helper.rb` |
| `requires` | array of strings | all | Array of other attribute names that must be filled/visible for this attribute to appear. Emitted as `data-attr-requires` for client-side show/hide logic. | `_attributes.html.erb` (line ~103) |
| `requires_message` | string | all | Message shown when the `requires` dependency is not met. | `_attributes.html.erb` (line ~104) |
| `write_in_file` | string | textfield | When set, the parameter value is written to a file (at the given filename within the run output directory) and replaced in the DB by a SHA2 hash. Used for large values. (Currently commented out but referenced in code.) | `basic.rb` (commented, lines ~3382-3400) |
| `obsolete` | boolean | all | When `true`, the attribute is hidden from the form. | `_attributes.html.erb` (line ~88) |

#### `input_gene_set_item` widget

Search/select widget for a gene set item from the global ASAP database. Used by the **module_score** step when `geneset_source` is `"global"`.

| Key | Type | Description | Handled in |
|-----|------|-------------|------------|
| `widget` | string | Must be `"input_gene_set_item"`. | `_attributes.html.erb` |
| `requires` | array | Typically `["global_gene_set_collection_id"]` and `["input_matrix"]`. | `_attributes.html.erb`, JS |
| `constraints.visible_if` | array | Show only when `geneset_source` equals `"global"`. | `form_req_controller.js` |
| `constraints.required_if` | array | Required when `geneset_source` equals `"global"`. | `reqs_controller.rb`, `form_req_controller.js` |
| `run_display` | object | Often combined with `global_gene_set_collection_id` into one badge. See section 1.5. | `application_helper.rb` |

The collection dropdown (`global_gene_set_collection_id`, widget `"select"`) has an empty `list` in JSON; at form render time `ProjectsController#inject_module_score_gene_set_collection_options!` fills it from the project's organism via the remote gene-set database.

The selected item ID is stored in `global_gene_set_item_id`. At run creation, `Basic.set_run` sets `global_gene_set_db_conn` automatically when `global_gene_set_item_id` is present, so the CLI can receive `-h` / `-geneset` flags via `command_json`.

Related attributes on **module_score** (in `Step#method_attrs_json`):

| Attribute | Role |
|-----------|------|
| `geneset_source` | `"global"` (ASAP database) or `"loom"` (row metadata in the LOOM). `not_null: true`. |
| `global_gene_set_collection_id` | Collection filter when source is global. |
| `global_gene_set_item_id` | Selected gene set item when source is global. |
| `geneset` | `input_data` row metadata when source is loom. |
| `geneset_sel` | Category/column within that metadata when source is loom. |

On submit, `ReqsController` strips attrs that do not apply to the chosen source (e.g. removes `geneset` / `geneset_sel` when source is global). Server-side validation: `validate_module_score_gene_set_constraints`.

#### Required vs optional (authoring convention)

Use **one signal per widget type** -- do not set both `not_null` and `optional` on the same attribute.

| Widget | Optional | Required |
|--------|----------|----------|
| `input_data` | `min_nber_items: 0` | `min_nber_items: 1` (or higher) |
| `textfield`, `select`, `checkbox`, ... | omit `not_null`, or `not_null: false` | `not_null: true` |

Runtime interpretation is centralized in `FormAttrConstraints` (`lib/form_attr_constraints.rb`), used by the form UI (`form_attr_required?`), method availability gating (`optional_std_method_input_attr?`), and client-side validation (`data-attr-not-null`).

Step-level shared inputs (e.g. `input_matrix` on tSNE/UMAP) live in `Step#method_attrs_json` and typically use `min_nber_items` only. Method-specific scalars (e.g. `perplexity`, `nber_dims`) live in `StdMethod#attrs_json` and use `not_null`.

### 1.4 Constraints sub-object

The `constraints` key holds a hash with two supported sub-keys:

#### `visible_if`

Shows or hides the field in the form when another attribute has a specific value. Evaluated client-side in `form_req_controller.js` (same entry format as `required_if`).

**Array form** (preferred):
```json
{
  "constraints": {
    "visible_if": [
      { "attr": "geneset_source", "equals": "global" }
    ]
  }
}
```

All entries are ANDed: the field is visible only when every condition is true.

#### `required_if`

Makes the field required only when another attribute has a specific value. Evaluated server-side in `reqs_controller.rb` `validate_required_if_constraints` and client-side in `form_req_controller.js`.

**Array form** (preferred):
```json
{
  "constraints": {
    "required_if": [
      { "attr": "geneset_source", "equals": "global" }
    ]
  }
}
```

**Hash form** (shorthand):
```json
{
  "constraints": {
    "required_if": {
      "some_other_attr": "some_value"
    }
  }
}
```

All entries are ANDed: the field becomes required only when every condition is true. The `equals` comparison normalizes booleans and strings.

### 1.5 `run_display` sub-object

Controls how a run parameter appears in run badges and summaries (after submission), independent of form layout.

| Key | Type | Description |
|-----|------|-------------|
| `show_when_default` | boolean | When `true`, show this attr in run badges even when its value equals the default (e.g. `geneset_source` default `"global"`). |
| `composite` | boolean | When `true`, this attr drives a combined badge with other attrs. |
| `composite_label` | string | Label for the combined badge (e.g. `"Gene set"`). |
| `merge_with` | array of strings | Other attr names merged into this composite badge and hidden individually (e.g. `["global_gene_set_collection_id"]`). |
| `visible_when` | array | Same shape as `visible_if`; controls when the composite badge is shown. |
| `resolver` | string | Badge value resolver. `"global_gene_set_item"` resolves collection + item IDs to human-readable labels via `GlobalGeneSetDisplayLabels`. |
| `description` | string | Help text on the composite badge. |

Example (module_score `global_gene_set_item_id`):
```json
{
  "run_display": {
    "composite": true,
    "composite_label": "Gene set",
    "merge_with": ["global_gene_set_collection_id"],
    "visible_when": [{ "attr": "geneset_source", "equals": "global" }],
    "resolver": "global_gene_set_item",
    "description": "Global database gene set used for module scoring."
  }
}
```

---

## 2. `command_json`

### 2.1 Structure overview

A JSON **object** that describes the CLI program to run inside a Docker container. It holds the program entrypoint, CLI flags/arguments, and run-time prediction configuration.

```json
{
  "program": "Rscript --vanilla normalization.v8.R",
  "docker_image": "asap",
  "opts": [
    { "opt": "-f", "param_key": "input_matrix_filename" },
    { "opt": "--method", "value": "LogNormalize" },
    { "opt": "--output_meta", "param_key": "output_matrix_dataset", "value": "/layers/normalized_ln" },
    { "opt": "--output_dir", "param_key": "output_dir" }
  ],
  "args": [
    { "param_key": "some_positional", "value": "#{output_dir}/result.txt" }
  ],
  "predict_params": ["nber_cols", "nber_rows", "std_method_name"]
}
```

### 2.2 Merge logic with `Step#command_json`

At run creation (`ReqsController`, `RunsController`, marker methods in `basic.rb`):

```ruby
h_cmd_params = JSON.parse(step.command_json)
tmp_h = JSON.parse(std_method.command_json)
tmp_h.each_key { |k| h_cmd_params[k] = tmp_h[k] }
```

StdMethod keys **fully override** Step keys at the top level. Typically, `docker_image` and `host_name` come from the Step, while `program`, `opts`, and `predict_params` come from the StdMethod. If both define `opts`, the StdMethod's array replaces the Step's entirely.

### 2.3 Top-level key reference

| Key | Type | Typical source | Description | Handled in |
|-----|------|----------------|-------------|------------|
| `program` | string | StdMethod | CLI entrypoint string (e.g. `"Rscript --vanilla normalization.v8.R"`, `"python3.12 normalize.v8.py"`). Displayed in admin UI via `StdMethod#command_program`. Copied to the final Run `command_json`. | `std_method.rb`, `basic.rb` set_run |
| `docker_image` | string | Step | Key into `version.env_json['docker_images']` to select the Docker image (e.g. `"asap"`). Required after merge; `set_run` errors if missing. | `basic.rb` set_run (line ~3655) |
| `host_name` | string | Step | Docker host. Defaults to `"localhost"` if absent. | `basic.rb` set_run (line ~3649) |
| `opts` | array of objects | StdMethod or Step | CLI **named flags** (e.g. `--method LogNormalize`). Each entry is a hash; see section 2.4. | `basic.rb` set_run (line ~3635) |
| `args` | array of objects | StdMethod or Step | CLI **positional arguments**. Each entry is a hash; see section 2.4. | `basic.rb` set_run (line ~3619) |
| `predict_params` | array of strings | StdMethod | List of parameter names used for run duration/RAM prediction (e.g. `["nber_cols", "nber_rows", "std_method_name"]`). Their resolved values are passed to the prediction R script. Also read by `get_run_stats` and `set_predict_params`. | `basic.rb` set_run (line ~3692), `set_predict_params`, `get_run_stats` |
| `db_json` | object | StdMethod or Step | Specifies a JSON file to be written in the run output directory before the container starts, containing Annot row data. Used by DE methods (e.g. `de.v8.py`). See section 2.5. | `basic.rb` `write_de_db_json!` |
| `group1_use_category_index` | boolean | (legacy) | Legacy DE flag: use 0-based category index for `group_ref` instead of the label string. | `basic.rb` `command_json_use_category_index_for_de_group?` |
| `group2_use_category_index` | boolean | (legacy) | Same for `group_comp`. | same |
| `group1` | object | (legacy) | Nested legacy form: `{ "use_category_index": true }`. | same |
| `group2` | object | (legacy) | Same for group2. | same |

### 2.4 `opts` / `args` entry reference

Each entry in `opts[]` or `args[]` is a JSON object. For `opts`, the entry produces `<opt> <value>` on the command line. For `args`, it produces just `<value>`.

| Key | Type | Applies to | Description | Handled in |
|-----|------|------------|-------------|------------|
| `opt` | string | opts only | The CLI flag (e.g. `"-f"`, `"--method"`, `"--output_dir"`). | `basic.rb` set_run (line ~3645) |
| `param_key` | string | both | Links this entry to a run attribute or `h_var` key. The resolved value comes from (in order): `value` field > `h_var[param_key]` > `std_method_attr[param_key]['default']`. | `basic.rb` set_run (lines ~3622, ~3638) |
| `value` | string | both | Static value, or a template string with `#{var_name}` placeholders that get substituted from `h_var`. When both `value` and `param_key` are set, `value` takes precedence. | `basic.rb` set_run |
| `null_value` | string | both | Literal value used on the command line when the resolved value is blank/nil. The entry is **not** skipped; instead, `null_value` appears in place of the empty value. | `basic.rb` set_run (line ~3630, ~3645) |
| `omit_when_null` | boolean | both | When `true`, the entire entry (flag + value) is **skipped** if the resolved value is blank after template expansion. Takes precedence over `null_value`. | `basic.rb` `skip_command_json_arg_or_opt_entry?` (line ~685) |
| `valueless_flag` | boolean | opts | When `true`, the entry is **skipped** if the resolved value is falsy; when truthy, only the flag name is emitted (e.g. `--chunked`) with **no** following argument. Use for Python/argparse `store_true` flags driven by checkbox attrs. | `basic.rb` `skip_command_json_arg_or_opt_entry?`, `set_run`, `command_json_opt_shell_fragment` |
| `omit_when_all_against_compl` | boolean | both | When `true`, the entry is skipped if the run attribute `all_against_compl` is truthy. Used for DE flags that should be dropped in all-against-complementary mode (e.g. `--group1`, `--group2`). | `basic.rb` `skip_command_json_arg_or_opt_entry?` (line ~679) |
| `use_annot_id` | boolean | both | When `true`, the resolved value (a metadata column name) is replaced by the numeric `Annot` database ID before being passed to the CLI. Applied by `apply_de_annot_ids_from_command_json!`. | `basic.rb` `de_param_keys_requiring_annot_id` (line ~700), `apply_de_annot_ids_from_command_json!` |
| `use_group_category_index` | boolean | both | When `true`, the group label string is replaced by its **0-based index** in the annotation's category list. Applied by `apply_de_group_category_indices_from_command_json!`. | `basic.rb` `command_json_group_category_mode_for_entry` (line ~649) |
| `use_group_category_pos` | boolean | both | When `true`, the group label is replaced by its **1-based position** (index + 1). Takes priority over `use_group_category_index` if both are set. | `basic.rb` `command_json_group_category_mode_for_entry` (line ~648) |
| `category_annot_param_key` | string | both | When set (e.g. `"groups2"`), the category index lookup uses the annotation from this other attribute instead of the default `groups` annotation. If that attribute is empty, falls back to `groups`. | `basic.rb` `apply_de_group_category_indices_from_command_json!` (line ~1312) |

#### Built-in `h_var` keys (always available in `set_run`)

These keys are populated before opts/args resolution and can be used as `param_key` or in `#{...}` templates inside `value`:

| Key | Source | Example use |
|-----|--------|-------------|
| `std_method_name` | `StdMethod#name` | Dataset paths, bulk clustering `--method` |
| `std_method_label` | `StdMethod#label`, fallback `Step#label` | Display-oriented CLI flags |
| `std_method_short_label` | `StdMethod#short_label`, fallback `Step#short_label` | CLI method names (e.g. Seurat `RunTSNE` via `--method`) |
| `step_tag` | `Step#tag` | Output dataset naming |
| `step_name` | `Step#name` | Logging, paths |
| `run_num` | `Run#num` | Output dataset naming |
| `output_dir` | Run output directory path | `-o`, `--output_dir` |
| `project_dir` | Project root on disk | File paths |

Example (Seurat t-SNE / UMAP):

```json
{ "opt": "--method", "param_key": "std_method_short_label" }
```

resolves to `RunTSNE` or `RunUMAP` from the std_method's `short_label` column.

#### Value resolution order (for each entry)

1. `entry['value']` (static or template)
2. `h_var[entry['param_key']]` (resolved from run attrs / dataset selections)
3. `std_method_attrs[entry['param_key']]['default']` (from attrs_json)
4. If still blank: `entry['null_value']` is used, unless `omit_when_null` is set (then the entry is skipped entirely)

Template expansion: any `#{var_name}` in the value string is replaced with `h_var['var_name']`.

### 2.5 `db_json` sub-object

Used by DE methods to dump Annot row data to a JSON file in the run output directory before the container starts.

| Key | Type | Description |
|-----|------|-------------|
| `filename` | string | Output file name. Defaults to `"db.json"` if absent or blank. |
| `annots` | array of strings | List of `h_var` param keys whose resolved values are annotation IDs (comma-separated if multiple). The system collects all unique annot IDs, loads the full `Annot` rows, and writes them as `{"annots": [{...}, ...]}`. |
| `annot_ids` | array of integers | **Not set in the template.** Written by `set_run` after resolution, so the final Run `command_json` records which annot IDs were used. |

Example template (in merged command_json):
```json
{
  "db_json": {
    "filename": "db.json",
    "annots": ["metadata", "groups_annot_id", "groups2_annot_id"]
  }
}
```

### 2.6 Legacy top-level DE keys

These are older alternatives to putting `use_group_category_index` on individual `opts[]` entries:

```json
{
  "group1_use_category_index": true,
  "group2_use_category_index": true
}
```

Or the nested form:
```json
{
  "group1": { "use_category_index": true },
  "group2": { "use_category_index": true }
}
```

`group1` maps to param_key `group_ref`, `group2` maps to `group_comp`. Checked by `command_json_use_category_index_for_de_group?` and folded into `de_group_category_mode_by_param_key`.

### 2.7 Final Run `command_json` (output of `set_run`)

After `set_run` processes the merged template, it builds a new `command_json` that is saved on the `Run` record. This final form contains:

| Key | Source |
|-----|--------|
| `host_name` | From merged command_json or `"localhost"` |
| `container_name` | Generated: `ASAP_INSTANCE_NAME + "_" + run.id` |
| `docker_call` | From `env_json['docker_images'][key]['call']` with image name interpolated |
| `time_call` | From `env_json['time_call']` with `h_var` interpolation |
| `exec_stdout` | From `env_json['exec_stdout']` with `h_var` interpolation |
| `exec_stderr` | From `env_json['exec_stderr']` with `h_var` interpolation |
| `program` | From merged `command_json['program']` |
| `args` | Resolved array: each entry has `param_key` and `value` (final) |
| `opts` | Resolved array: each entry has `opt`, `param_key`, and `value` (final) |
| `db_json` | Enriched with `annot_ids` (only present if `db_json` was in template) |
| `expected_duration` | From prediction model (if predictable) |
| `expected_ram` | From prediction model (if predictable) |

---

## 3. Related JSON columns on StdMethod

These are **separate columns**, not part of `attrs_json` or `command_json`:

| Column | Default | Description |
|--------|---------|-------------|
| `attr_layout_json` | `"[]"` | Array of layout sections that control how `attrs_json` parameters are arranged in the form. References parameter names via `attr_list` arrays. |
| `obj_attrs_json` | `"{}"` | Method-level metadata flags: `handles_log` (boolean), `project_types` (array of strings like `["sc"]`), `allowed_downstream_steps` (array of step names). |
| `output_json` | `"{}"` | Describes expected output structure. |

---

## 4. Concrete example

Below is the full `command_json` generated for the v8 LogNormalize (Seurat) normalization StdMethod, as built by `NormalizationV8StdMethods.command_json_for`:

```json
{
  "program": "Rscript --vanilla normalization.v8.R",
  "opts": [
    { "opt": "-f", "param_key": "input_matrix_filename" },
    { "opt": "--input_meta", "param_key": "input_matrix_dataset" },
    { "opt": "--method", "value": "LogNormalize" },
    { "opt": "--output_meta", "param_key": "output_matrix_dataset", "value": "/layers/normalized_ln" },
    { "opt": "--output_dir", "param_key": "output_dir" }
  ],
  "predict_params": ["nber_cols", "nber_rows", "std_method_name"]
}
```

For this method, `attrs_json` is `"{}"` (empty) -- all form parameters come from `Step#method_attrs_json` via the merge in `get_std_method_attrs`.

A DE-style method might look like:

```json
{
  "program": "python3.12 de.v8.py",
  "opts": [
    { "opt": "-f", "param_key": "input_matrix_filename" },
    { "opt": "--group1", "param_key": "group_ref", "use_group_category_index": true, "omit_when_null": true },
    { "opt": "--group2", "param_key": "group_comp", "use_group_category_index": true, "category_annot_param_key": "groups2", "omit_when_null": true },
    { "opt": "-meta", "param_key": "metadata", "use_annot_id": true },
    { "opt": "--output_dir", "param_key": "output_dir" }
  ],
  "db_json": {
    "filename": "db.json",
    "annots": ["metadata", "groups_annot_id", "groups2_annot_id"]
  },
  "predict_params": ["nber_cols", "nber_rows", "std_method_name"]
}
```

### Module score gene set inputs

The **module_score** step defines form attrs in `Step#method_attrs_json` (not in `StdMethod#attrs_json`). Users choose a gene set source, then either pick from the global database or from LOOM row metadata.

**Form attrs** (simplified; see step id 122 in DB):

```json
{
  "geneset_source": {
    "label": "Gene set source",
    "widget": "select",
    "list": [["Global database", "global"], ["Loom row metadata", "loom"]],
    "default": "global",
    "not_null": true,
    "run_display": { "show_when_default": true }
  },
  "global_gene_set_collection_id": {
    "label": "Gene set collection",
    "widget": "select",
    "list": [],
    "constraints": {
      "visible_if": [{ "attr": "geneset_source", "equals": "global" }],
      "required_if": [{ "attr": "geneset_source", "equals": "global" }]
    }
  },
  "global_gene_set_item_id": {
    "label": "Gene set",
    "widget": "input_gene_set_item",
    "constraints": {
      "visible_if": [{ "attr": "geneset_source", "equals": "global" }],
      "required_if": [{ "attr": "geneset_source", "equals": "global" }]
    },
    "run_display": {
      "composite": true,
      "composite_label": "Gene set",
      "merge_with": ["global_gene_set_collection_id"],
      "visible_when": [{ "attr": "geneset_source", "equals": "global" }],
      "resolver": "global_gene_set_item"
    }
  },
  "geneset": {
    "label": "Gene set metadata",
    "widget": "input_data",
    "min_nber_items": 1,
    "constraints": {
      "visible_if": [{ "attr": "geneset_source", "equals": "loom" }],
      "required_if": [{ "attr": "geneset_source", "equals": "loom" }]
    }
  },
  "geneset_sel": {
    "label": "Gene set category",
    "widget": "select",
    "constraints": {
      "visible_if": [{ "attr": "geneset_source", "equals": "loom" }],
      "required_if": [{ "attr": "geneset_source", "equals": "loom" }]
    }
  }
}
```

**StdMethod `command_json`** (Seurat ModuleScore) uses `omit_when_null` so only the active source is passed:

```json
{
  "program": "java -jar /srv/ASAP.jar",
  "opts": [
    { "opt": "-T", "value": "ModuleScore" },
    { "opt": "-metadata", "param_key": "geneset_dataset", "omit_when_null": true },
    { "opt": "-sel", "param_key": "geneset_sel", "omit_when_null": true },
    { "opt": "-geneset", "param_key": "global_gene_set_item_id", "omit_when_null": true },
    { "opt": "-h", "param_key": "global_gene_set_db_conn", "omit_when_null": true },
    { "opt": "-loom", "param_key": "input_matrix_filename" },
    { "opt": "-dataset", "param_key": "input_matrix_dataset" }
  ]
}
```

- **Global path:** `-geneset` (item id) + `-h` (DB connection URL auto-set in `Basic.set_run`).
- **Loom path:** `-metadata` (dataset) + `-sel` (category column).

**Form layout** (`attr_layout_json`): input matrix on its own row; gene set attrs and other parameters in a two-column row (`Input geneset` | `Other parameters`).

---

## 5. Key source files

| File | Role |
|------|------|
| `src/lib/basic.rb` | `get_std_method_attrs` (merge), `set_run` (command resolution), DE annot/index helpers, value resolution |
| `src/lib/form_attr_constraints.rb` | Canonical required/optional rules; `optional` to `not_null` / `min_nber_items` migration |
| `src/lib/normalization_v8_std_methods.rb` | Only in-repo programmatic `command_json` builder; `attrs_json` is `"{}"` |
| `src/app/views/projects/views/_attributes.html.erb` | Form rendering using all `attrs_json` options |
| `src/app/controllers/reqs_controller.rb` | Run creation, `validate_required_if_constraints`, `combinatorial_runs` |
| `src/app/controllers/runs_controller.rb` | Run restart with rebuilt `command_json` |
| `src/app/helpers/application_helper.rb` | Run badge display, `run_display` composites, `default`-based hiding |
| `src/app/javascript/controllers/form_req_controller.js` | Client-side `visible_if` / `required_if`, form validation |
| `src/app/javascript/controllers/gene_set_item_selector_controller.js` | `input_gene_set_item` search/select widget |
| `src/lib/global_gene_set_display_labels.rb` | Human-readable labels for module_score gene set badges |
| `src/app/models/std_method.rb` | `command_program` display from `command_json['program']` |
| `src/app/controllers/std_methods_controller.rb` | Admin CRUD, permits both columns |
| `src/lib/reference_data_steps_std_methods_sync.rb` | Sync/export treating both as JSON text columns |
| `src/lib/tasks/migrate_optional_to_not_null.rake` | One-time migration: `optional` -> `min_nber_items` / `not_null` |
| `src/db/schema.rb` | Column definitions |
