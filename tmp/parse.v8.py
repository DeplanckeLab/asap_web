from __future__ import annotations
import dataclasses
from dataclasses import dataclass, field, asdict
from typing import Dict, List, Optional, Set, Tuple, Any, Final
from contextlib import contextmanager
import psycopg2 # Postgresql adapter
from psycopg2.extensions import connection as PGConnection # Postgresql adapter
from psycopg2.extras import RealDictCursor # Postgresql adapter
from urllib.parse import urlparse # For parsing host string
import argparse # Needed to parse arguments
import sys # Needed for ErrorJSON
import os # Needed for pathjoin and path/create dirs
import h5py # Needed for parsing hdf5 files
import json # For writing output files
import numpy as np # For diverse array calculations
import re # Regex for gene to db comparison
from pathlib import Path # Needed for file extension manipulation
from collections import Counter # To count categories occurrences
import scipy.sparse as sp # For handling sparse matrices
import polars as pl # For fast-reading text matrices (csv, tsv, ...)
import rpy2.robjects as ro # For reading RDS files
from rpy2.robjects.packages import importr # For reading RDS files
from rpy2.robjects import pandas2ri
import pandas as pd # For handling dataframes (especially used with RDS files)

## Constants
# For defining variable as categorical (arbitrary thresholds)
CATEGORICAL_NMIN: Final[int] = 10 # Less than 10 unique values = categorical
CATEGORICAL_NMAX: Final[int] = 500 # More than 500 unique values = non-categorical
CATEGORICAL_PC_UNIQUE: Final[float] = 0.10 # Else, categorical only if unique values < 10% of all values
DEFAULT_BLOCK_CELLS: Final[int] = 1024 # For reading in chunks
LOOM_FILENAME: Final[str] = "output.loom" # Output LOOM file name
LOOM_CHUNK_GENES: Final[int] = 1024 # Output LOOM chunked policy (rows)
LOOM_CHUNK_CELLS: Final[int] = 1024 # Output LOOM chunked policy (cols)
LOOM_COMPRESSION: Final[str] = "gzip" # Output LOOM compression
LOOM_COMPRESSION_LEVEL: Final[int] = 4 # Output LOOM compression level
LOOM_DTYPE: Final[str] = "float32" # Output LOOM numeric format
DEFAULT_DB_PORT: Final[int] = 5432 # Default DB port for PostgreSQL
DEFAULT_CONNECT_TIMEOUT: Final[int] = 10 # Default DB connection timeout for PostgreSQL
DEFAULT_RIBO_GO_TERM: Final[str] = "GO:0003735" # GO Term used for inferring ribo genes for QC
DEFAULT_TEXT_DELIM: Final[str] = "\t" # For TextHandler, default delim
DEFAULT_NP_DTYPE = np.float64 # Keeping internal best precision

## Format Handlers

# Helper
def _is_compound_dataset(node: h5py.HLObject) -> bool:
    return isinstance(node, h5py.Dataset) and node.dtype.fields is not None

class H5ADHandler:
    
    @staticmethod
    def get_size(f: h5py.File, path: str) -> tuple[int, int]:
        node = f[path]
        shape = node.attrs.get("shape", None)
        if shape is None:
            shape = node.attrs.get("h5sparse_shape", None)
        if shape is not None:
            return tuple(int(x) for x in shape)

        if isinstance(node, h5py.Dataset):
            return tuple(int(x) for x in node.shape)

        if isinstance(node, h5py.Group) and all(k in node for k in ("data", "indices", "indptr")):
            enc = node.attrs.get("encoding-type", "csr_matrix")
            if isinstance(enc, bytes): enc = enc.decode()
            enc = str(enc)
            major = int(node["indptr"].shape[0] - 1)
            max_idx = int(np.max(node["indices"][:])) if int(node["indices"].shape[0]) else -1
            minor = int(max_idx + 1) if max_idx >= 0 else 0
            if enc == "csr_matrix":
                return (major, minor)  # (cells, genes)
            if enc == "csc_matrix":
                return (minor, major)  # (genes, cells) - swapped because H5AD CSC has genes as columns
            ErrorJSON(f"Unsupported encoding-type={enc!r} at {path}")

        ErrorJSON(f"Could not determine shape for {path}")

    @staticmethod
    def extract_index(f: h5py.File, path: str) -> list[str]:
        node = f[path]
        if isinstance(node, h5py.Group):
            raw = node.attrs.get("_index", "index")
            index_col_name = raw.decode() if isinstance(raw, bytes) else raw
            full_path = f"{path.rstrip('/')}/{index_col_name.lstrip('/')}"
            if full_path not in f:
                full_path = f"{path.rstrip('/')}/_index"
            return [v.decode() if isinstance(v, bytes) else str(v) for v in f[full_path][:]]
        if _is_compound_dataset(node):
            raw = node.attrs.get("_index", None)
            index_field = raw.decode() if isinstance(raw, bytes) else raw
            candidates = ([index_field] if index_field else []) + ["_index", "index", "obs_names", "var_names"]
            for c in candidates:
                if c in (node.dtype.names or ()):
                    vals = node[c]
                    if getattr(vals, "dtype", None) is not None and vals.dtype.kind in ("S", "O", "U"):
                        return [v.decode() if isinstance(v, (bytes, np.bytes_)) else str(v) for v in vals]
                    return [str(v) for v in vals]
            ErrorJSON(f"Could not find index field in compound table {path}.")
        ErrorJSON(f"Unsupported obs/var node at {path}")

    @staticmethod
    def _table_columns(f, table_path: str):
        """Extract column names from obs/var table."""
        if table_path not in f:
            return []
        
        node = f[table_path]
        if isinstance(node, h5py.Group):
            cols = node.attrs.get('_column_names', list(node.keys()))
            if isinstance(cols, np.ndarray):
                cols = cols.tolist()
            return cols
        elif _is_compound_dataset(node):
            return list(node.dtype.names or [])
        else:
            return []

    @staticmethod
    def _find_categories_for_column(f, table_path: str, col: str):
        """
        Returns list[str] categories if found, else None.
        Looks in old-style __categories, cat, raw/cat, and uns locations.
        """
        candidates = []
        
        # Categories attached to table
        candidates.append(f"{table_path.rstrip('/')}/__categories/{col}")
        candidates.append(f"{table_path.rstrip('/')}/cat/{col}")
        
        # Raw-specific category store
        if table_path.startswith("raw/") or table_path.startswith("/raw/"):
            candidates.append("raw/cat/" + col)
            candidates.append("/raw/cat/" + col)
        
        # Top-level /cat
        candidates.append("cat/" + col)
        candidates.append("/cat/" + col)
        
        for p in candidates:
            if p in f and isinstance(f[p], h5py.Dataset):
                cats = f[p][:]
                return [v.decode() if isinstance(v, (bytes, np.bytes_)) else str(v) for v in cats]

        # Fallback: categories stored in uns as "<col>_categories"
        for p in (f"uns/{col}_categories", f"/uns/{col}_categories"):
            if p in f and isinstance(f[p], h5py.Dataset):
                cats = f[p][:]
                return [v.decode() if isinstance(v, (bytes, np.bytes_)) else str(v) for v in cats]
        
        return None

    @staticmethod
    def _decode_enum_if_needed(item: h5py.Dataset) -> np.ndarray | None:
        """If dataset is H5T_ENUM, decode integer codes to string labels. Returns None if not enum."""
        enum_dict = h5py.check_enum_dtype(item.dtype)
        if enum_dict is None:
            return None
        # Invert {label: code} -> {code: label}
        code_to_label = {v: k for k, v in enum_dict.items()}
        codes = item[:]
        return np.array([code_to_label.get(int(c), "nan") for c in codes.flat], dtype=object).reshape(codes.shape)
    
    @staticmethod
    def _detect_sparse_encoding(node: h5py.Group, n_cells: int, n_genes: int) -> str:
        enc = node.attrs.get("encoding-type", None)
        if isinstance(enc, bytes): enc = enc.decode()
        enc = str(enc) if enc is not None else None

        indptr_len = int(node["indptr"].shape[0])
        if indptr_len == n_cells + 1: inferred = "csr_matrix"
        elif indptr_len == n_genes + 1: inferred = "csc_matrix"
        else:
            ErrorJSON(f"Cannot infer sparse encoding: len(indptr)={indptr_len}, expected {n_cells+1} or {n_genes+1}")

        return inferred

    @staticmethod
    def _create_h5ad_block_reader(f: h5py.File, src_path: str, n_cells: int, n_genes: int):
        """
        Creates a block reader function for H5AD matrices.
        Returns: get_block(start, end) -> ndarray(cells x genes)
        """
        node = f[src_path]
        is_sparse = isinstance(node, h5py.Group) and all(k in node for k in ("data", "indices", "indptr"))
        is_dense = isinstance(node, h5py.Dataset)
        
        if not (is_sparse or is_dense):
            ErrorJSON(f"Unsupported matrix layout at {src_path}")
        
        if is_dense:
            def get_block(start, end): return node[start:end, :]  # cells x genes
            return get_block
        
        # Detect sparse encoding
        enc = H5ADHandler._detect_sparse_encoding(node, n_cells, n_genes)
        
        if enc == "csr_matrix":
            # Hybrid loading - pre-load pointers, lazy-load data
            indptr_full = node["indptr"][:]  # Small array (~200 KB)
            ds_indices = node["indices"]     # Keep as HDF5 reference (lazy)
            ds_data = node["data"]           # Keep as HDF5 reference (lazy)
            
            def get_block(start, end):
                ptr = indptr_full[start:end + 1].astype(np.int64)
                p0, p1 = int(ptr[0]), int(ptr[-1])
                
                # Empty block optimization
                if p0 == p1: return sp.csr_matrix((end - start, n_genes), dtype=DEFAULT_NP_DTYPE)
                
                # Load only needed data from disk
                indptr_local = (ptr - p0).astype(np.int64, copy=False)
                block_indices = ds_indices[p0:p1]
                block_data = ds_data[p0:p1]
                
                # Return sparse CSR directly (no .toarray())
                return sp.csr_matrix((block_data.astype(DEFAULT_NP_DTYPE, copy=False), block_indices.astype(np.int64, copy=False), indptr_local), shape=(end - start, n_genes))
            return get_block
        elif enc == "csc_matrix":
            # CSC: Loading entire matrix and converting to CSR...
            X_csc = sp.csc_matrix((node["data"][:], node["indices"][:], node["indptr"][:]), shape=(n_cells, n_genes), dtype=DEFAULT_NP_DTYPE)
            csr_view = X_csc.tocsr()
            
            def get_block(start, end):
                # Extract rows (cells) start:end from the CSR view
                return csr_view[start:end, :]
    
            return get_block
        else:
            ErrorJSON(f"Unsupported sparse encoding: {enc}")

    @staticmethod
    def _transfer_metadata(f, group_path, loom, result, n_cells, n_genes, orientation, existing_paths):
        """
        Transfer obs (CELL) or var (GENE) metadata from H5AD to Loom.
        Handles categorical decoding (codes→categories).
        """
        if group_path not in f:
            return
        
        cols = H5ADHandler._table_columns(f, group_path)
        if not cols:
            return
        
        # Skip these internal columns
        skip_cols = {"_index", "categories", "codes", "__categories", "cat"}
        
        # Identify index column name if available
        node = f[group_path]
        index_col = None
        if isinstance(node, h5py.Group):
            index_col = node.attrs.get('_index', '_index')
            if isinstance(index_col, bytes):
                index_col = index_col.decode()
        
        for col in cols:
            if col in skip_cols or (index_col and col == index_col):
                continue
            
            loom_path = f"/{'col' if orientation == 'CELL' else 'row'}_attrs/{col}"
            if loom_path in existing_paths:
                result.setdefault("warnings", []).append(f"Skipping {group_path}/{col} -> {loom_path} transfer: already exists.")
                continue
            
            values = None
            
            # ---- CASE 1: Group-based column ----
            if isinstance(node, h5py.Group):
                item = node[col]
                
                # New-style categorical group: {categories, codes}
                if isinstance(item, h5py.Group) and 'categories' in item and 'codes' in item:
                    cats = [v.decode() if isinstance(v, bytes) else str(v) for v in item['categories'][:]]
                    codes = item['codes'][:]
                    values = np.array([cats[c] if c != -1 else "nan" for c in codes], dtype=object)
                
                # Old-style categorical: codes in dataset, categories elsewhere
                elif isinstance(item, h5py.Dataset) and np.issubdtype(item.dtype, np.integer):
                    cats = H5ADHandler._find_categories_for_column(f, group_path, col)
                    if cats is not None:
                        codes = item[:]
                        def map_code(c):
                            if c == -1: return "nan"
                            c = int(c)
                            return cats[c] if 0 <= c < len(cats) else "nan"
                        values = np.array([map_code(c) for c in codes], dtype=object)
                    else:
                        values = item[:]
                
                else:
                    decoded = H5ADHandler._decode_enum_if_needed(item)
                    if decoded is not None:
                        values = decoded
                    else:
                        raw_values = item[:]
                        if raw_values.dtype.kind in ('S', 'U', 'O'):
                            values = np.array([v.decode() if isinstance(v, bytes) else str(v) for v in raw_values], dtype=object)
                        else:
                            values = raw_values
            
            # ---- CASE 2: Compound dataset ----
            else:
                raw_values = node[col]
                
                # If integer codes and categories exist, decode them
                if np.issubdtype(np.array(raw_values).dtype, np.integer):
                    cats = H5ADHandler._find_categories_for_column(f, group_path, col)
                    if cats is not None:
                        def map_code(c):
                            if c == -1: return "nan"
                            c = int(c)
                            return cats[c] if 0 <= c < len(cats) else "nan"
                        values = np.array([map_code(c) for c in raw_values], dtype=object)
                    else:
                        values = raw_values
                else:
                    if np.array(raw_values).dtype.kind in ('S', 'U', 'O'):
                        values = np.array([v.decode() if isinstance(v, (bytes, np.bytes_)) else str(v) for v in raw_values], dtype=object)
                    else:
                        values = raw_values
            
            if values is None:
                continue

            # ASAP.jar ExtractMetadata does not handle boolean metadata arrays reliably.
            # Normalize booleans to string categories so they behave like standard discrete metadata.
            values_array = np.asarray(values)
            if np.issubdtype(values_array.dtype, np.bool_):
                values = np.where(values_array, "True", "False").astype(object)
            
            # Dimension check
            expected_len = n_cells if orientation == "CELL" else n_genes
            if len(values) != expected_len:
                entity = "cells" if orientation == "CELL" else "genes"
                result.setdefault("warnings", []).append(f"Skipping {col} from {group_path}: length mismatch. Expected {expected_len} {entity}, but found {len(values)}.")
                continue
            
            # Write using LoomFile's write_metadata
            meta = loom.write_metadata(values, loom_path, n_cells=n_cells, n_genes=n_genes, imported=1)
            result["metadata"].append(meta)
            existing_paths.add(loom_path)

    @staticmethod
    def _transfer_multidimensional_metadata(f, group_path, loom, result, n_cells, n_genes, orientation, existing_paths):
        """
        Transfer obsm (CELL) or varm (GENE) multidimensional matrices.
        Examples: PCA, UMAP, tSNE embeddings.
        """
        if group_path not in f:
            return
        
        group = f[group_path]
        if not isinstance(group, h5py.Group):
            return
        
        prefix = "col" if orientation == "CELL" else "row"
        
        for key in group.keys():
            loom_path = f"/{prefix}_attrs/{key}"
            
            if loom_path in existing_paths:
                result.setdefault("warnings", []).append(f"Skipping {group_path}/{key} -> {loom_path} transfer: already exists.")
                continue
            
            try:
                item = group[key]
                
                if not isinstance(item, h5py.Dataset):
                    result.setdefault("warnings", []).append(f"Skipping {group_path}/{key}: not a dataset.")
                    continue
                
                # Dimension check
                expected_n = n_cells if orientation == "CELL" else n_genes
                actual_shape = item.shape
                if actual_shape[0] != expected_n:
                    result.setdefault("warnings", []).append(f"Skipping {group_path}/{key}: dimension mismatch. Expected {expected_n} {orientation.lower()}s, but found {actual_shape[0]}.")
                    continue
                
                # Handle compound datasets
                if _is_compound_dataset(item):
                    H5ADHandler._write_compound_and_register(item, loom, result, n_cells, n_genes, orientation, loom_path, existing_paths)
                    continue
                
                # Normal multidim write
                data = item[:]
                meta = loom.write_metadata(data, loom_path, n_cells=n_cells, n_genes=n_genes, imported=1)
                result["metadata"].append(meta)
                existing_paths.add(loom_path)
                
            except Exception as e:
                result.setdefault("warnings", []).append(f"Could not transfer {group_path}/{key}: {str(e)}")

    @staticmethod
    def _transfer_layers(f, loom, result, n_cells, n_genes, existing_paths, input_group):
        """
        Transfer H5AD /layers/* and alternative main matrices to Loom /layers.
        """
        
        # 1. Transfer explicit /layers/* (spliced/unspliced, normalized, etc.)
        if "/layers" in f:
            for layer_name in f["/layers"].keys():
                layer_path = f"/layers/{layer_name}"
                dest_path = f"/layers/{layer_name}"
                
                if dest_path in existing_paths:
                    result.setdefault("warnings", []).append(f"Skipping {layer_path} -> {dest_path} transfer: already exists.")
                    continue
                
                try:
                    l_cells, l_genes = H5ADHandler.get_size(f, layer_path)
                    if l_cells != n_cells or l_genes != n_genes:
                        result.setdefault("warnings", []).append(f"Skipping layer {layer_name}: dimension mismatch (expected {n_cells}x{n_genes}, found {l_cells}x{l_genes})")
                        continue
                    
                    # Write layer without heavy stats (gene_metadata=None)
                    block_reader = H5ADHandler._create_h5ad_block_reader(f=f, src_path=layer_path, n_cells=n_cells, n_genes=n_genes)
                    layer_stats = loom.write_expression_matrix(get_block=block_reader, n_cells=n_cells, n_genes=n_genes, gene_metadata=None, dest_path=dest_path)
                    
                    # Register metadata
                    meta = Metadata(name=dest_path, on="EXPRESSION_MATRIX", type="NUMERIC", nber_rows=n_genes, nber_cols=n_cells, dataset_size=loom.get_dataset_size(dest_path), nber_zeros=layer_stats["total_zeros"], is_count_table=layer_stats["is_count_table"], imported=1)
                    result["metadata"].append(meta)
                    existing_paths.add(dest_path)
                    
                except Exception as e:
                    result.setdefault("warnings", []).append(f"Failed to transfer layer {layer_name}: {str(e)}")
        
        # 2. Transfer alternative main matrices to /layers
        #    (e.g., if /X was selected as primary, save /raw/X and /raw.X as layers)
        candidates = ["/X", "/raw/X", "/raw.X"]
        
        for candidate in candidates:
            # Skip if not present or is the primary matrix
            if candidate not in f or candidate == input_group:
                continue
            
            try:
                c_cells, c_genes = H5ADHandler.get_size(f, candidate)
                if c_cells != n_cells or c_genes != n_genes:
                    result.setdefault("warnings", []).append(f"Skipping alternative matrix {candidate}: dimension mismatch (expected {n_cells}x{n_genes}, found {c_cells}x{c_genes})")
                    continue
                
                # Create safe layer name (e.g., "/raw/X" → "raw_X")
                layer_name = candidate.strip("/").replace("/", "_")
                dest_path = f"/layers/{layer_name}"
                
                if dest_path in existing_paths:
                    result.setdefault("warnings", []).append(f"Skipping {candidate} -> {dest_path} transfer: already exists.")
                    continue
                
                # Write alternative matrix as a layer without heavy stats (gene_metadata=None)
                block_reader = H5ADHandler._create_h5ad_block_reader(f=f, src_path=candidate, n_cells=n_cells, n_genes=n_genes)
                alt_stats = loom.write_expression_matrix(get_block=block_reader, n_cells=n_cells, n_genes=n_genes, gene_metadata=None, dest_path=dest_path)
                
                # Register metadata
                meta = Metadata(name=dest_path, on="EXPRESSION_MATRIX", type="NUMERIC", nber_rows=n_genes, nber_cols=n_cells, dataset_size=loom.get_dataset_size(dest_path), nber_zeros=alt_stats["total_zeros"], is_count_table=alt_stats["is_count_table"], imported=1)
                result["metadata"].append(meta)
                existing_paths.add(dest_path)
                
            except Exception as e:
                result.setdefault("warnings", []).append(f"Could not transfer alternative matrix {candidate}: {str(e)}")

    @staticmethod
    def _transfer_unstructured_metadata(f, loom, result, n_cells, n_genes, existing_paths):
        """
        Transfer uns (unstructured global metadata) from H5AD to Loom /attrs.
        Skips categorical lookup tables (*_categories, *_levels, *_codes).
        """
        if "uns" not in f:
            return
        
        def should_skip_uns_key(key: str) -> bool:
            """Skip categorical lookup tables."""
            k = key.lower()
            return k.endswith("_categories") or k.endswith("_levels") or k.endswith("_codes")
        
        def walk(group, prefix=""):
            for key in group.keys():
                item = group[key]
                attr_name = f"{prefix}{key}"
                
                if should_skip_uns_key(attr_name):
                    continue
                
                loom_path = f"/attrs/{attr_name}"
                
                if isinstance(item, h5py.Group):
                    walk(item, prefix=f"{attr_name}_")
                    continue
                
                if not isinstance(item, h5py.Dataset):
                    continue
                
                if loom_path in existing_paths:
                    result.setdefault("warnings", []).append(f"Skipping /uns/{attr_name} -> {loom_path} transfer: already exists.")
                    continue
                
                # Handle compound datasets
                if _is_compound_dataset(item):
                    H5ADHandler._write_compound_and_register(item, loom, result, n_cells, n_genes, "GLOBAL", loom_path, existing_paths)
                    continue
                
                try:
                    decoded = H5ADHandler._decode_enum_if_needed(item)
                    if decoded is not None:
                        val = decoded
                    else:
                        val = item[()]
                    if isinstance(val, (bytes, np.bytes_)):
                        val = val.decode("utf-8")
                    elif isinstance(val, np.ndarray) and val.dtype.kind in ("S", "U"):
                        val = np.array([v.decode("utf-8") if isinstance(v, bytes) else str(v) for v in val.flatten()]).reshape(val.shape)

                    meta = loom.write_metadata(val, loom_path, n_cells=n_cells, n_genes=n_genes, imported=1)
                    result["metadata"].append(meta)
                    existing_paths.add(loom_path)
                    
                except Exception as e:
                    result.setdefault("warnings", []).append(f"Skipping uns item {attr_name}: {str(e)}")
        
        walk(f["uns"])

    @staticmethod
    def _write_compound_and_register(src_obj: h5py.Dataset, loom, result: dict, n_cells: int, n_genes: int, orientation: str, loom_path: str, existing_paths: set[str]) -> None:
        """Write a compound/structured HDF5 dataset into Loom as a regular (non-compound) dataset.
        - If the compound dtype has 1 field, writes it as a 1D vector.
        - If it has multiple fields, writes it as a 2D matrix (n_rows × n_fields).
        """
        if loom_path in existing_paths: 
            result.setdefault("warnings", []).append(f"Skipping {src_obj.name} -> {loom_path} transfer: already exists.")
            return

        try:
            fields = list(src_obj.dtype.names or [])
            if not fields:
                result.setdefault("warnings", []).append(f"Skipping compound dataset {loom_path}: no fields.")
                return

            data = src_obj[()]  # structured ndarray (possibly >1D)
            arr = np.asarray(data)
            data_flat = arr.reshape(-1) if arr.ndim > 1 else arr
            n_rows = int(data_flat.shape[0])

            def field_is_numeric(fname: str) -> bool:
                dt = src_obj.dtype.fields[fname][0]
                return np.issubdtype(dt, np.number) or np.issubdtype(dt, np.bool_)

            all_numeric = all(field_is_numeric(f) for f in fields)

            if len(fields) == 1:
                col = np.asarray(data_flat[fields[0]]).reshape(-1)
                if col.dtype.kind in ("S", "O", "U"):
                    col = np.array([v.decode(errors="ignore") if isinstance(v, (bytes, np.bytes_)) else str(v) for v in col], dtype=object)
                meta = loom.write_metadata(col, loom_path, n_cells=n_cells, n_genes=n_genes, imported=1)
                result["metadata"].append(meta)
                existing_paths.add(loom_path)
                return

            if all_numeric:
                mat = np.empty((n_rows, len(fields)), dtype=DEFAULT_NP_DTYPE)
                for j, f_ in enumerate(fields):
                    mat[:, j] = np.asarray(data_flat[f_], dtype=DEFAULT_NP_DTYPE)
            else:
                mat = np.empty((n_rows, len(fields)), dtype=object)
                for j, f_ in enumerate(fields):
                    col = np.asarray(data_flat[f_]).reshape(-1)
                    mat[:, j] = [v.decode(errors="ignore") if isinstance(v, (bytes, np.bytes_)) else str(v) for v in col]

            meta = loom.write_metadata(mat, loom_path, n_cells=n_cells, n_genes=n_genes, imported=1)
            result["metadata"].append(meta)
            existing_paths.add(loom_path)

        except Exception as e:
            result.setdefault("warnings", []).append(f"Could not write compound dataset {loom_path}: {e}")

    @staticmethod
    def parse(args, file_path: str, out_dir: Path, gene_db: MapGene, loom, result):

        with h5py.File(file_path, "r") as f:
            if args.sel is not None:
                if args.sel not in f:
                    ErrorJSON(f"--sel path {args.sel!r} not found")
                input_group = args.sel
            else:
                candidates = ["/X", "/raw/X", "/raw.X"]
                matches = [g for g in candidates if g in f]
                if len(matches) == 0:
                    ErrorJSON(f"No candidate matrix found in {candidates}. Provide --sel.")
                if len(matches) > 1:
                    ErrorJSON(f"Multiple candidate matrices found {matches}. Provide --sel.")
                input_group = matches[0]

            result["input_group"] = input_group
            n_cells, n_genes = H5ADHandler.get_size(f, input_group)
            result["nber_cols"] = int(n_cells)
            result["nber_rows"] = int(n_genes)

            var_path = "/var"
            obs_path = "/obs"
            obsm_path = "/obsm"
            varm_path = "/varm"
            if input_group == "/raw.X":
                var_path = "/raw.var" if "/raw.var" in f else var_path
                obs_path = "/raw.obs" if "/raw.obs" in f else obs_path
                obsm_path = "/raw.obsm" if "/raw.obsm" in f else obsm_path
                varm_path = "/raw.varm" if "/raw.varm" in f else varm_path
            elif input_group == "/raw/X":
                var_path = "/raw/var" if "/raw/var" in f else var_path
                obs_path = "/raw/obs" if "/raw/obs" in f else obs_path
                obsm_path = "/raw/obsm" if "/raw/obsm" in f else obsm_path
                varm_path = "/raw/varm" if "/raw/varm" in f else varm_path

            gene_names = H5ADHandler.extract_index(f, var_path)
            cell_ids = H5ADHandler.extract_index(f, obs_path)

            parsed_genes, _ = loom.write_names_and_gene_db(cell_ids=cell_ids, original_gene_names=gene_names, gene_db=gene_db, output_dir=out_dir, result=result, n_cells=n_cells, n_genes=n_genes)

            # Write Expression Matrix
            block_reader = H5ADHandler._create_h5ad_block_reader(f=f, src_path=input_group, n_cells=n_cells, n_genes=n_genes)
            stats = loom.write_expression_matrix(get_block=block_reader, n_cells=n_cells, n_genes=n_genes, gene_metadata=parsed_genes, dest_path="/matrix")

            ## Transfer Metadata
            existing_paths = (input_group | {m.name for m in result["metadata"]} | LoomFile._reserved_paths())
            
            # Transfer OBS (Cells)
            H5ADHandler._transfer_metadata(f, obs_path, loom, result, n_cells, n_genes, "CELL", existing_paths)
            if obs_path != "/obs":
                H5ADHandler._transfer_metadata(f, "/obs", loom, result, n_cells, n_genes, "CELL", existing_paths) # Because I still want to copy everything from there if correct size.
            
            # Transfer VAR (Genes)
            H5ADHandler._transfer_metadata(f, var_path, loom, result, n_cells, n_genes, "GENE", existing_paths)
            if var_path != "/var":
                H5ADHandler._transfer_metadata(f, "/var", loom, result, n_cells, n_genes, "GENE", existing_paths) # Because I still want to copy everything from there if correct size.
            
            # Transfer OBSM (Cell Embeddings)
            H5ADHandler._transfer_multidimensional_metadata(f, obsm_path, loom, result, n_cells, n_genes, "CELL", existing_paths)
            if obsm_path != "/obsm": 
                H5ADHandler._transfer_multidimensional_metadata(f, "/obsm", loom, result, n_cells, n_genes, "CELL", existing_paths) # Because I still want to copy everything from there if correct size.
            
            # Transfer VARM (Gene Embeddings)
            H5ADHandler._transfer_multidimensional_metadata(f, varm_path, loom, result, n_cells, n_genes, "GENE", existing_paths)
            if varm_path != "/varm": 
                H5ADHandler._transfer_multidimensional_metadata(f, "/varm", loom, result, n_cells, n_genes, "GENE", existing_paths) # Because I still want to copy everything from there if correct size.

            # Transfer uns (unstructured global metadata)
            H5ADHandler._transfer_unstructured_metadata(f, loom, result, n_cells, n_genes, existing_paths)

            # Transfer Layers + Alternative matrices like 'spliced'/'unspliced' or 'transformed'
            H5ADHandler._transfer_layers(f, loom, result, n_cells, n_genes, existing_paths, input_group)

        return stats

class LoomHandler:
    @staticmethod
    def _find_first_existing(f: h5py.File, paths: list[str]) -> str | None:
        for p in paths:
            if p in f:
                return p
        return None

    @staticmethod
    def _as_str_list(arr) -> list[str]:
        """
        Convert HDF5 array to list of strings, handling bytes/numpy types.
        Used for reading cell IDs and gene names from Loom files.
        """
        flat = arr.ravel() if isinstance(arr, np.ndarray) else arr
        out = []
        for v in flat:
            if isinstance(v, (bytes, np.bytes_, np.void)):
                out.append(v.decode(errors="ignore"))
            else:
                out.append(str(v))
        return out

    @staticmethod
    def _infer_cell_ids(f: h5py.File, n_cells: int) -> list[str]:
        candidates = [
            "/col_attrs/CellID", "/col_attrs/cell_id", "/col_attrs/cell_ids",
            "/col_attrs/barcode", "/col_attrs/barcodes", "/col_attrs/Barcode",
            "/col_attrs/obs_names", "/col_attrs/index", "/col_attrs/_index",
        ]
        p = LoomHandler._find_first_existing(f, candidates)
        if p and isinstance(f[p], h5py.Dataset):
            vals = f[p][:]
            cell_ids = LoomHandler._as_str_list(vals)
            if len(cell_ids) == n_cells:
                return cell_ids
        return [f"Cell_{i+1}" for i in range(n_cells)]

    @staticmethod
    def _infer_gene_names(f: h5py.File, n_genes: int) -> list[str]:
        """
        Per-gene fallback across multiple candidate row_attrs vectors:
        for each gene i, take the first non-empty value from the ordered candidates.
        If all candidates are empty/missing for a gene, fall back to "Gene_{i+1}".
        """
        candidates = [
            "/row_attrs/Accession", "/row_attrs/Name", "/row_attrs/Gene", "/row_attrs/Original_Gene",
            "/row_attrs/gene", "/row_attrs/gene_name", "/row_attrs/var_names",
            "/row_attrs/index", "/row_attrs/_index",
        ]
        
        # Load all usable candidate vectors (must exist, be dataset, and have correct length)
        loaded: list[tuple[str, list[str]]] = []
        for p in candidates:
            if p in f and isinstance(f[p], h5py.Dataset):
                try:
                    vals = f[p][:]
                    vec = LoomHandler._as_str_list(vals)
                except Exception:
                    continue
                if len(vec) == n_genes:
                    loaded.append((p, vec))
        
        if not loaded:
            return [f"Gene_{i+1}" for i in range(n_genes)]
        
        def is_empty(s: str) -> bool:
            if s is None:
                return True
            ss = str(s).strip()
            return (ss == "" or ss.lower() in {"nan", "null", "0"})
        
        # Per-gene fallback: first non-empty across loaded candidates
        out: list[str] = []
        for i in range(n_genes):
            chosen = None
            for p, vec in loaded:
                v = vec[i]
                if not is_empty(v):
                    chosen = str(v).strip()
                    break
            
            if chosen is None:
                out.append(f"Gene_{i+1}")
            else:
                out.append(chosen)
        
        return out

    @staticmethod
    def _create_loom_block_reader(f: h5py.File, src_path: str, n_cells: int, n_genes: int):
        """
        Creates a block reader for Loom matrices.
        Returns: get_block(start, end) -> ndarray(cells x genes)
        """
        node = f[src_path]
        if not isinstance(node, h5py.Dataset):
            ErrorJSON(f"Unsupported Loom matrix layout at {src_path}: expected dataset")
        
        if tuple(node.shape) != (n_genes, n_cells):
            ErrorJSON(f"Matrix dimension mismatch at {src_path}: expected {(n_genes, n_cells)}, got {tuple(node.shape)}")
        
        def get_block(start, end):
            block_gxc = np.array(node[:, start:end], copy=False)  # genes x cells
            return block_gxc.T  # cells x genes
        
        return get_block

    @staticmethod
    def _transfer_other_datasets(src_f: h5py.File, loom: LoomFile, result: dict, n_cells: int, n_genes: int, existing_paths: set[str]):
        """
        Transfer all other datasets from source Loom file to output Loom file.
        """
        skip_prefixes = ("/matrix",)
        
        def should_skip(full_path: str) -> bool:
            if full_path in existing_paths:
                result.setdefault("warnings", []).append(f"Skipping {full_path} -> {full_path} transfer: already exists.")
                return True
            for spx in skip_prefixes:
                if full_path == spx or full_path.startswith(spx + "/"):
                    return True
            return False

        def write_compound_as_regular(obj: h5py.Dataset, full_path: str) -> None:
            fields = list(obj.dtype.names or [])
            if not fields:
                result["warnings"].append(f"Skipping compound dataset {full_path}: no fields.")
                return
            data = obj[:]  # structured ndarray
            data_flat = data.reshape(-1) if data.ndim > 1 else data
            n_rows = int(data_flat.shape[0])

            def field_is_numeric(fname: str) -> bool:
                dt = obj.dtype.fields[fname][0]
                return np.issubdtype(dt, np.number) or np.issubdtype(dt, np.bool_)

            all_numeric = all(field_is_numeric(f) for f in fields)

            if len(fields) == 1:
                col = np.asarray(data_flat[fields[0]]).reshape(-1)
                if col.dtype.kind in ("S", "O", "U"):
                    col = np.array([v.decode(errors="ignore") if isinstance(v, (bytes, np.bytes_)) else str(v) for v in col], dtype=object)
                meta = loom.write_metadata(col, full_path, n_cells=n_cells, n_genes=n_genes, imported=1)
                result["metadata"].append(meta)
                existing_paths.add(full_path)
                return

            if all_numeric:
                mat = np.empty((n_rows, len(fields)), dtype=DEFAULT_NP_DTYPE)
                for j, f_ in enumerate(fields):
                    mat[:, j] = np.asarray(data_flat[f_], dtype=DEFAULT_NP_DTYPE)
            else:
                mat = np.empty((n_rows, len(fields)), dtype=object)
                for j, f_ in enumerate(fields):
                    col = np.asarray(data_flat[f_]).reshape(-1)
                    mat[:, j] = [v.decode(errors="ignore") if isinstance(v, (bytes, np.bytes_)) else str(v) for v in col]

            meta = loom.write_metadata(mat, full_path, n_cells=n_cells, n_genes=n_genes, imported=1)
            result["metadata"].append(meta)
            existing_paths.add(full_path)

        def visitor(name: str, obj):
            full_path = "/" + name if not name.startswith("/") else name
            if not isinstance(obj, h5py.Dataset):
                return
            if should_skip(full_path):
                return
            try:
                if _is_compound_dataset(obj):
                    write_compound_as_regular(obj, full_path)
                    return
                val = obj[()]
                meta = loom.write_metadata(val, full_path, n_cells=n_cells, n_genes=n_genes, imported=1)
                result["metadata"].append(meta)
                existing_paths.add(full_path)
            except Exception as e:
                result["warnings"].append(f"Could not copy dataset {full_path}: {e}")

        src_f.visititems(visitor)

    @staticmethod
    def parse(args, file_path: str, out_dir: Path, gene_db: MapGene, loom, result):

        with h5py.File(file_path, "r") as f:
            matrix_path = args.sel or LoomHandler._find_first_existing(f, ["/matrix"])
            if not matrix_path or matrix_path not in f:
                ErrorJSON("Could not find Loom main matrix. Provide --sel or ensure /matrix exists.")
            node = f[matrix_path]
            if not isinstance(node, h5py.Dataset) or len(node.shape) != 2:
                ErrorJSON(f"Unsupported Loom main matrix at {matrix_path}")

            n_genes, n_cells = int(node.shape[0]), int(node.shape[1])
            result["nber_rows"] = n_genes
            result["nber_cols"] = n_cells
            result["input_group"] = matrix_path

            cell_ids = LoomHandler._infer_cell_ids(f, n_cells)
            gene_names = LoomHandler._infer_gene_names(f, n_genes)

            parsed_genes, _ = loom.write_names_and_gene_db(cell_ids=cell_ids, original_gene_names=gene_names, gene_db=gene_db, output_dir=out_dir, result=result, n_cells=n_cells, n_genes=n_genes)

            block_reader = LoomHandler._create_loom_block_reader(f=f, src_path=matrix_path, n_cells=n_cells, n_genes=n_genes)
            stats = loom.write_expression_matrix(get_block=block_reader, n_cells=n_cells, n_genes=n_genes, gene_metadata=parsed_genes, dest_path="/matrix")

            ## Transfer Metadata
            existing_paths = ({m.name for m in result["metadata"]} | LoomFile._reserved_paths())

            LoomHandler._transfer_other_datasets(src_f=f, loom=loom, result=result, n_cells=n_cells, n_genes=n_genes, existing_paths=existing_paths)

        return stats

class H510xHandler:
    @staticmethod
    def _find_10x_groups(f: h5py.File) -> list[str]:
        out = []
        for key in f.keys():
            if isinstance(f[key], h5py.Group):
                grp = f[key]
                if {"barcodes", "data", "indices", "indptr", "shape"}.issubset(grp.keys()):
                    out.append(key)
        return out

    @staticmethod
    def _pick_group(f: h5py.File, sel: str | None) -> str:
        candidates = H510xHandler._find_10x_groups(f)
        if sel is not None:
            if sel in f and isinstance(f[sel], h5py.Group):
                grp = f[sel]
                if {"barcodes", "data", "indices", "indptr", "shape"}.issubset(grp.keys()):
                    return sel
                ErrorJSON(f"--sel {sel!r} is not a valid 10x group.")
            ErrorJSON(f"--sel {sel!r} not found.")
        if len(candidates) == 0:
            ErrorJSON("No valid 10x matrix group found.")
        if len(candidates) > 1:
            ErrorJSON(f"Multiple 10x groups found: {candidates}. Use --sel.")
        return candidates[0]

    @staticmethod
    def _decode_list(arr) -> list[str]:
        out = []
        for v in arr:
            if isinstance(v, (bytes, np.bytes_, np.void)):
                try:
                    out.append(v.decode(errors="ignore"))
                except Exception:
                    out.append(str(v))
            else:
                out.append(str(v))
        return out

    @staticmethod
    def _read_feature_names(grp: h5py.Group, n_genes: int) -> list[str]:
        if "gene_names" in grp:
            vec = H510xHandler._decode_list(grp["gene_names"][:])
            return (vec + [f"Gene_{i+1}" for i in range(len(vec), n_genes)])[:n_genes]
        if "genes" in grp:
            vec = H510xHandler._decode_list(grp["genes"][:])
            return (vec + [f"Gene_{i+1}" for i in range(len(vec), n_genes)])[:n_genes]
        if "features" in grp and isinstance(grp["features"], h5py.Group):
            fg = grp["features"]
            if "name" in fg:
                vec = H510xHandler._decode_list(fg["name"][:])
            elif "id" in fg:
                vec = H510xHandler._decode_list(fg["id"][:])
            else:
                vec = []
            return (vec + [f"Gene_{i+1}" for i in range(len(vec), n_genes)])[:n_genes]
        return [f"Gene_{i+1}" for i in range(n_genes)]

    @staticmethod
    def _create_10x_block_reader(grp: h5py.Group, n_cells: int, n_genes: int):
        """
        Creates a block reader for 10x CSC sparse matrices.
        Returns: get_block(start, end) -> ndarray(cells x genes)
        """
        for k in ("data", "indices", "indptr", "shape"):
            if k not in grp:
                ErrorJSON(f"10x group missing '{k}'")
        
        shape = tuple(int(x) for x in grp["shape"][:])
        if shape != (n_genes, n_cells):
            ErrorJSON(f"10x shape mismatch: expected {(n_genes, n_cells)}, got {shape}")
        
        # Hybrid loading - pre-load pointers, lazy-load data
        indptr_full = grp["indptr"][:]  # Small array (~200 KB)
        ds_indices = grp["indices"]     # Keep as HDF5 reference (lazy)
        ds_data = grp["data"]           # Keep as HDF5 reference (lazy)

        if int(indptr_full.shape[0]) != n_cells + 1: ErrorJSON("Unexpected 10x indptr length (expected CSC with columns=cells).")

        def get_block(start, end):
            ptr = indptr_full[start:end + 1]
            ptr0, ptrN = int(ptr[0]), int(ptr[-1])
            
            # Empty block optimization
            if ptr0 == ptrN: return sp.csr_matrix((end - start, n_genes), dtype=DEFAULT_NP_DTYPE)
            
            # Calculate relative pointers for CSR construction
            indptr_local = (ptr - ptr0).astype(np.int64, copy=False)
            
            # Load only the data/indices required for this block from HDF5
            block_indices = ds_indices[ptr0:ptrN]
            block_data = ds_data[ptr0:ptrN]
            
            # Return sparse CSR directly (no .toarray(), no transpose)
            # Note: 10x is stored as CSC (genes × cells), we build CSR (cells × genes)
            return sp.csr_matrix((block_data.astype(DEFAULT_NP_DTYPE, copy=False), block_indices.astype(np.int64, copy=False), indptr_local), shape=(end - start, n_genes))
        
        return get_block

    @staticmethod
    def _transfer_10x_feature_extras(grp: h5py.Group, loom, result: dict, n_genes: int, n_cells: int, existing_paths: set[str]):
        """
        Write extra 10x features/* vectors into /row_attrs/<key>.
        """
        if "features" not in grp: return
        fg = grp["features"]
        # Make sure it's a group (not a dataset)
        if not hasattr(fg, "keys"): return

        for k in fg.keys():
            if k in {"name", "id"}: continue
            node = fg[k]
            if not hasattr(node, "shape"): continue # only datasets
            
            # must be feature-length vector
            try:
                if len(node.shape) != 1 or node.shape[0] != n_genes:
                    continue
            except Exception:
                continue

            path = f"/row_attrs/{k}"
            if path in existing_paths:
                result.setdefault("warnings", []).append(f"Skipping {grp}/features/{node} -> {path} transfer: already exists.")
                continue

            try:
                arr = node[:]
            except Exception:
                continue

            if hasattr(arr, "dtype") and arr.dtype.kind in ("S", "O", "U"):
                arr = np.array([v.decode(errors="ignore") if isinstance(v, (bytes, np.bytes_)) else str(v) for v in arr], dtype=object)

            meta = loom.write_metadata(arr, path, n_cells=n_cells, n_genes=n_genes, imported=1)
            result["metadata"].append(meta)
            existing_paths.add(path)

    @staticmethod
    def parse(args, file_path: str, out_dir: Path, gene_db: MapGene, loom: LoomFile, result):

        with h5py.File(file_path, "r") as f:
            group_name = H510xHandler._pick_group(f, args.sel)
            grp = f[group_name]
            result["input_group"] = group_name

            n_genes = int(grp["shape"][0])
            n_cells = int(grp["shape"][1])
            result["nber_rows"] = n_genes
            result["nber_cols"] = n_cells

            cell_ids = H510xHandler._decode_list(grp["barcodes"][:])
            cell_ids = (cell_ids + [f"Cell_{i+1}" for i in range(len(cell_ids), n_cells)])[:n_cells]
            gene_names = H510xHandler._read_feature_names(grp, n_genes)

            parsed_genes, _ = loom.write_names_and_gene_db(cell_ids=cell_ids, original_gene_names=gene_names, gene_db=gene_db, output_dir=out_dir, result=result, n_cells=n_cells, n_genes=n_genes)

            #stats = loom.write_expression_from_h510x(grp=grp, n_cells=n_cells, n_genes=n_genes, gene_metadata=parsed_genes, dest_path="/matrix")
            block_reader = H510xHandler._create_10x_block_reader(grp=grp, n_cells=n_cells, n_genes=n_genes)
            stats = loom.write_expression_matrix(get_block=block_reader, n_cells=n_cells, n_genes=n_genes, gene_metadata=parsed_genes, dest_path="/matrix")

            # Transfer extra 10x feature-level annotations into /row_attrs/*
            existing_paths = ({m.name for m in result["metadata"]} | LoomFile._reserved_paths())

            H510xHandler._transfer_10x_feature_extras(grp, loom, result, n_genes, n_cells, existing_paths)

        return stats

class RdsHandler:
    @staticmethod
    def _detect_object_class(obj):
        """Detect the class of the R object."""
        try:
            r = ro.r
            obj_class = r['class'](obj)[0]
            return str(obj_class)
        except Exception as e:
            ErrorJSON(f"Failed to detect RDS object class: {e}")
    
    @staticmethod
    def _extract_seurat_data(obj, args):
        """Extract matrix, genes, and cells from Seurat object."""
        try:
            r = ro.r
            Seurat = importr('Seurat')
            
            # Get assay list
            seurat_assays = [str(a) for a in r["Assays"](obj)]
            
            # Determine which assay to use
            if args.sel:
                if args.sel not in seurat_assays:
                    ErrorJSON(f"Specified assay '{args.sel}' not found in Seurat object. Available assays: {seurat_assays}")
                assay_name = args.sel
            else:
                if len(seurat_assays) == 0:
                    ErrorJSON("No assays found in Seurat object")
                elif len(seurat_assays) > 1:
                    ErrorJSON(f"Multiple assays found: {seurat_assays}. Use --sel to specify which assay to use.")
                assay_name = seurat_assays[0]
            
            # Check if "counts" layer exists in the assay
            layers_r = r(f'''function(obj) {{ assay <- "{assay_name}"; Layers(obj[[assay]]) }}''')(obj)
            layers = [str(x) for x in layers_r]
            
            if "counts" not in layers:
                ErrorJSON(f"Assay '{assay_name}' does not contain a 'counts' layer. Available layers: {layers}")
            
            # Get dimensions
            n_cells = int(list(r['ncol'](obj))[0])
            n_genes = int(list(r['nrow'](obj))[0])
            
            # Get gene and cell names
            gene_names = list(r['rownames'](obj))
            cell_ids = list(r['colnames'](obj))
            
            # Create block reader function for Seurat counts matrix
            def get_block(start, end):
                # Extract block from Seurat (cells x genes)
                # R uses 1-based indexing
                r_start = start + 1
                r_end = end
                
                block_r = r(f'''function(obj, start_col, end_col) {{ mat <- GetAssayData(obj, layer="counts", assay="{assay_name}"); block <- mat[, start_col:end_col, drop=FALSE]; as.matrix(t(block)) }}''')(obj, r_start, r_end)
                
                return np.array(block_r, dtype=DEFAULT_NP_DTYPE)
            
            return gene_names, cell_ids, n_genes, n_cells, get_block, assay_name
            
        except Exception as e:
            ErrorJSON(f"Failed to extract Seurat data: {e}")
    
    @staticmethod
    def _extract_dataframe_data(obj):
        """Extract matrix, genes, and cells from data.frame object."""
        try:
            pandas2ri.activate()
            
            # Convert R data.frame to pandas
            df = pandas2ri.rpy2py(obj)
            
            n_genes = len(df)
            n_cells = len(df.columns)
            
            # Get gene and cell names
            if hasattr(df, 'index') and len(df.index) > 0:
                gene_names = df.index.tolist()
            else:
                gene_names = [f"Gene_{i+1}" for i in range(n_genes)]
            
            cell_ids = df.columns.tolist()
            
            # Convert to numpy for numerical processing
            try:
                matrix_data = df.to_numpy(dtype=np.float64)
            except Exception as e:
                ErrorJSON(f"data.frame contains non-numeric values and cannot be converted to expression matrix: {e}")
            
            # Create block reader function for data.frame
            def get_block(start, end):
                return matrix_data[:, start:end].T.astype(DEFAULT_NP_DTYPE)
            
            return gene_names, cell_ids, n_genes, n_cells, get_block, "data_frame"
            
        except Exception as e:
            ErrorJSON(f"Failed to extract data.frame data: {e}")
    
    @staticmethod
    def _transfer_seurat_metadata(obj, assay_name, loom, result, n_cells, n_genes, existing_paths):
        """Transfer metadata from Seurat object to Loom."""
        try:           
            pandas2ri.activate()
            r = ro.r
            
            # Transfer cell metadata (meta.data)
            try:
                meta_data_r = r('''function(obj) { obj@meta.data }''')(obj)
                meta_df = pandas2ri.rpy2py(meta_data_r)
                
                for col in meta_df.columns:
                    loom_path = f"/col_attrs/{col}"
                    
                    if loom_path in existing_paths:
                        result.setdefault("warnings", []).append(f"Skipping Seurat meta.data column '{col}': path already exists.")
                        continue
                    
                    # Handle NA values properly to avoid sentinel values like -2147483648
                    series = meta_df[col]
                    
                    # R's integer NA sentinel value
                    R_INT_NA = -2147483648
                    
                    # Check for R's integer NA sentinel first
                    if pd.api.types.is_integer_dtype(series):
                        has_r_na = (series == R_INT_NA).any()
                        if has_r_na:
                            # Replace R's NA sentinel with actual NA
                            series = series.replace(R_INT_NA, pd.NA)
                    
                    # Now handle pandas NA values
                    if series.isna().all():
                        values = np.array(["nan"] * len(series), dtype=object)
                    elif series.isna().any():
                        if pd.api.types.is_numeric_dtype(series):
                            values = series.astype(object).apply(lambda x: "nan" if pd.isna(x) else x).to_numpy()
                        else:
                            values = series.fillna("nan").to_numpy()
                    else:
                        values = series.to_numpy()
                    
                    # Dimension check
                    if len(values) != n_cells:
                        result.setdefault("warnings", []).append(f"Skipping Seurat meta.data column '{col}': length mismatch (expected {n_cells}, found {len(values)}).")
                        continue
                    
                    meta = loom.write_metadata(values, loom_path, n_cells=n_cells, n_genes=n_genes, imported=1)
                    result["metadata"].append(meta)
                    existing_paths.add(loom_path)
                    
            except Exception as e:
                result.setdefault("warnings", []).append(f"Could not transfer Seurat meta.data: {str(e)}")
            
            # Transfer dimensional reductions (PCA, UMAP, tSNE, etc.)
            try:
                reductions = list(r['Reductions'](obj))
                
                for reduction_name in reductions:
                    try:
                        # Get embedding coordinates
                        embedding_r = r(f'''function(obj) {{ Embeddings(obj, reduction="{reduction_name}") }}''')(obj)
                        embedding = np.array(embedding_r, dtype=DEFAULT_NP_DTYPE)
                        
                        # Check dimensions
                        if embedding.shape[0] != n_cells:
                            result.setdefault("warnings", []).append(f"Skipping reduction '{reduction_name}': dimension mismatch (expected {n_cells} cells, found {embedding.shape[0]}).")
                            continue
                        
                        loom_path = f"/col_attrs/{reduction_name}"
                        
                        if loom_path in existing_paths:
                            result.setdefault("warnings", []).append(f"Skipping reduction '{reduction_name}': path already exists.")
                            continue
                        
                        meta = loom.write_metadata(embedding, loom_path, n_cells=n_cells, n_genes=n_genes, imported=1)
                        result["metadata"].append(meta)
                        existing_paths.add(loom_path)
                        
                    except Exception as e:
                        result.setdefault("warnings", []).append(f"Could not transfer reduction '{reduction_name}': {str(e)}")
                        
            except Exception as e:
                result.setdefault("warnings", []).append(f"Could not access Seurat reductions: {str(e)}")
            
            # Transfer additional layers (if any besides "counts")
            try:
                layers_r = r(f'''function(obj) {{ assay <- "{assay_name}"; Layers(obj[[assay]]) }}''')(obj)
                layers = [str(x) for x in layers_r]
                
                for layer_name in layers:
                    if layer_name == "counts":
                        continue  # Skip counts as it's already the main matrix
                    
                    try:
                        # Get layer dimensions first
                        layer_ncol = int(list(r(f'''function(obj) {{ ncol(GetAssayData(obj, layer="{layer_name}", assay="{assay_name}")) }}''')(obj))[0])
                        layer_nrow = int(list(r(f'''function(obj) {{ nrow(GetAssayData(obj, layer="{layer_name}", assay="{assay_name}")) }}''')(obj))[0])
                        
                        if layer_nrow != n_genes or layer_ncol != n_cells:
                            result.setdefault("warnings", []).append(f"Skipping layer '{layer_name}': dimension mismatch (expected {n_genes}x{n_cells}, found {layer_nrow}x{layer_ncol}).")
                            continue
                        
                        dest_path = f"/layers/{layer_name}"
                        
                        if dest_path in existing_paths:
                            result.setdefault("warnings", []).append(f"Skipping layer '{layer_name}': path already exists.")
                            continue
                        
                        # Create block reader for this layer
                        def get_layer_block(start, end, ln=layer_name, an=assay_name):
                            r_start = start + 1
                            r_end = end
                            block_r = r(f'''function(obj, start_col, end_col) {{ mat <- GetAssayData(obj, layer="{ln}", assay="{an}"); block <- mat[, start_col:end_col, drop=FALSE]; as.matrix(t(block)) }}''')(obj, r_start, r_end)
                            return np.array(block_r, dtype=DEFAULT_NP_DTYPE)
                        
                        # Write layer
                        layer_stats = loom.write_expression_matrix(get_block=get_layer_block, n_cells=n_cells, n_genes=n_genes, gene_metadata=None, dest_path=dest_path)
                        
                        # Register metadata
                        meta = Metadata(name=dest_path, on="EXPRESSION_MATRIX", type="NUMERIC", nber_rows=n_genes, nber_cols=n_cells, dataset_size=loom.get_dataset_size(dest_path), nber_zeros=layer_stats["total_zeros"], is_count_table=layer_stats["is_count_table"], imported=1)
                        result["metadata"].append(meta)
                        existing_paths.add(dest_path)
                        
                    except Exception as e:
                        result.setdefault("warnings", []).append(f"Could not transfer layer '{layer_name}': {str(e)}")
                        
            except Exception as e:
                result.setdefault("warnings", []).append(f"Could not access Seurat layers: {str(e)}")
                
        except Exception as e:
            result.setdefault("warnings", []).append(f"Error during Seurat metadata transfer: {str(e)}")
    
    @staticmethod
    def parse(args, file_path: str, out_dir: Path, gene_db: MapGene, loom, result):       
        # Initialize R and load RDS file
        r = ro.r
        base = importr('base')
        obj = base.readRDS(file_path)
        
        # Detect object class
        obj_class = RdsHandler._detect_object_class(obj)
        result["input_group"] = obj_class
        
        # Extract data based on object type
        if obj_class == "Seurat":
            gene_names, cell_ids, n_genes, n_cells, get_block, group_name = RdsHandler._extract_seurat_data(obj, args)
        elif obj_class == "data.frame":
            gene_names, cell_ids, n_genes, n_cells, get_block, group_name = RdsHandler._extract_dataframe_data(obj)
        else:
            ErrorJSON(f"Unsupported RDS object type: {obj_class}. Only 'Seurat' and 'data.frame' are supported.")
        
        # Update result with dimensions
        result["nber_rows"] = n_genes
        result["nber_cols"] = n_cells
        if obj_class == "Seurat":
            result["input_group"] = f"Seurat/{group_name}"
        else:
            result["input_group"] = group_name
        
        # Write gene and cell names + gene database info
        parsed_genes, _ = loom.write_names_and_gene_db(cell_ids=cell_ids, original_gene_names=gene_names, gene_db=gene_db, output_dir=out_dir, result=result, n_cells=n_cells, n_genes=n_genes)
        
        # Write main expression matrix
        stats = loom.write_expression_matrix(get_block=get_block, n_cells=n_cells, n_genes=n_genes, gene_metadata=parsed_genes, dest_path="/matrix")
        
        # Transfer metadata
        existing_paths = ({m.name for m in result["metadata"]} | LoomFile._reserved_paths())
        
        if obj_class == "Seurat":
            RdsHandler._transfer_seurat_metadata(obj, group_name, loom, result, n_cells, n_genes, existing_paths)
        
        return stats

class MtxHandler:
    """
    Handler for Matrix Market (MTX) format files.
    Expects either:
    - A single matrix.mtx file, OR
    - A triplet: matrix.mtx + barcodes.tsv + (features.tsv | genes.tsv)
    """
    @staticmethod
    def _discover_mtx_files(matrix_path: str) -> tuple[str, str | None, str | None]:
        """
        Discover the MTX triplet files (matrix, barcodes, features).
        """       
        matrix_dir = Path(matrix_path).parent
        
        # Find barcodes file
        barcode_candidates = ['barcodes.tsv', 'barcodes.csv']
        barcodes_path = None
        for name in barcode_candidates:
            candidate = matrix_dir / name
            if candidate.exists():
                barcodes_path = str(candidate)
                break
                        
        # Find features/genes file
        feature_candidates = ['features.tsv', 'genes.tsv', 'features.csv', 'genes.csv', 'gene_names.csv', 'features.csv']
        features_path = None
        for name in feature_candidates:
            candidate = matrix_dir / name
            if candidate.exists():
                features_path = str(candidate)
                break
        
        return matrix_path, barcodes_path, features_path

    @staticmethod
    def _read_barcodes(file_path: str) -> list[str]:
        """
        Read cell barcodes from barcodes file.
        Supports TSV (one barcode per line) and CSV (with optional headers).
        """
        import csv
        
        try:
            if file_path.endswith('.tsv'):
                with open(file_path, 'r') as f:
                    lines = [line.strip() for line in f if line.strip()]
                    
                    # Check if first line has multiple columns (likely a header)
                    has_header = lines and lines[0].count('\t') > 0
                    start_idx = 1 if has_header else 0
                    
                    # Extract first tab-delimited field from each line
                    return [line.split('\t')[0].strip('"') for line in lines[start_idx:]]
                    
            elif file_path.endswith('.csv'):
                with open(file_path, 'r') as f:
                    reader = csv.DictReader(f)
                    # Use 'barcode' column if it exists, otherwise use first column
                    return [row.get('barcode', list(row.values())[0]) for row in reader]
            else:
                ErrorJSON(f"Unsupported barcode file format: {file_path}")
                
        except Exception as e:
            ErrorJSON(f"Failed to read barcodes file {file_path}: {str(e)}")
    
    @staticmethod
    def _read_features(file_path: str) -> tuple[list[str], list[str]]:
        """
        Read gene/feature information from features file.
        Returns: (gene_ids, gene_names)
        
        Supports:
        - features.tsv/genes.tsv: tab-separated (gene_id, gene_name, [feature_type])
        - gene_names*.csv: one gene per line, no header
        """
        
        try:
            with open(file_path, 'r') as f:
                if file_path.endswith('.tsv'):
                    lines = [line.strip().split('\t') for line in f if line.strip()]
                    gene_ids = [parts[0] for parts in lines if parts]
                    gene_names = [parts[1] if len(parts) >= 2 else parts[0] for parts in lines if parts]
                    return gene_ids, gene_names
                elif file_path.endswith('.csv'):
                    genes = [line.strip() for line in f if line.strip()]
                    return genes, genes
                else:
                    ErrorJSON(f"Unsupported features file format: {file_path}")
                    
        except Exception as e:
            ErrorJSON(f"Failed to read features file {file_path}: {str(e)}")
    
    @staticmethod
    def _parse_mtx_header(matrix_path: str) -> tuple[int, int, int, bool]:
        """
        Parse MTX header to get dimensions and format.
        Returns: (n_genes, n_cells, nnz, is_pattern)
        """
        is_pattern = False
        n_genes = n_cells = nnz = -1
        
        try:
            with open(matrix_path, 'r') as f:
                # Read first line (format specification)
                first_line = f.readline().strip()
                if not first_line.startswith('%%MatrixMarket'):
                    ErrorJSON(f"Invalid MTX file: missing MatrixMarket header in {matrix_path}")
                
                # Check if it's a pattern matrix (binary)
                if 'pattern' in first_line.lower():
                    is_pattern = True
                
                # Skip comment lines
                for line in f:
                    if line.startswith('%'):
                        continue
                    # Parse dimension line
                    parts = line.strip().split()
                    if len(parts) != 3:
                        ErrorJSON(f"Invalid MTX dimension line in {matrix_path}: expected 3 values, got {len(parts)}")
                    n_genes, n_cells, nnz = map(int, parts)
                    break
                else:
                    ErrorJSON(f"MTX file {matrix_path} has no dimension line")
        except Exception as e:
            ErrorJSON(f"Failed to parse MTX header from {matrix_path}: {str(e)}")
        
        return n_genes, n_cells, nnz, is_pattern
    
    @staticmethod
    def _create_mtx_block_reader(matrix_path: str, n_genes: int, n_cells: int, nnz: int, is_pattern: bool):
        """
        Create a block reader for MTX files.
        Returns: get_block(start, end) -> scipy.sparse.csr_matrix (cells x genes)
        
        Strategy: Read entire MTX into memory as COO, convert to CSR, then slice by cells.
        """
        # Read all coordinate data
        rows = np.zeros(nnz, dtype=np.int32)
        cols = np.zeros(nnz, dtype=np.int32)
        data = np.ones(nnz, dtype=DEFAULT_NP_DTYPE) if is_pattern else np.zeros(nnz, dtype=DEFAULT_NP_DTYPE)
        
        try:
            with open(matrix_path, 'r') as f:
                # Skip header and comments
                for line in f:
                    if not line.startswith('%'):
                        break  # We've already read dimension line, skip it
                
                # Read data lines
                idx = 0
                for line in f:
                    parts = line.strip().split()
                    if not parts:
                        continue
                    
                    if is_pattern:
                        if len(parts) != 2:
                            continue
                        row, col = map(int, parts)
                        val = 1.0
                    else:
                        if len(parts) != 3:
                            continue
                        row, col = map(int, parts[:2])
                        val = float(parts[2])
                    
                    if idx >= nnz:
                        break
                    
                    # MTX is 1-indexed, convert to 0-indexed
                    rows[idx] = row - 1
                    cols[idx] = col - 1
                    data[idx] = val
                    idx += 1
        except Exception as e:
            ErrorJSON(f"Failed to read MTX data from {matrix_path}: {str(e)}")
        
        # Create COO matrix (genes x cells)
        coo = sp.coo_matrix((data, (rows, cols)), shape=(n_genes, n_cells), dtype=DEFAULT_NP_DTYPE)
        
        # Convert to CSC for efficient column slicing (cells are columns)
        csc = coo.tocsc()
        
        def get_block(start: int, end: int):
            """
            Extract cells from start to end.
            Returns: sparse CSR matrix of shape (cells x genes)
            """
            # Slice columns (cells) from CSC matrix -> still CSC with shape (genes, end-start)
            block_csc = csc[:, start:end]
            # Transpose to (cells x genes) and convert to CSR for efficient row operations
            block_csr = block_csc.T.tocsr()
            return block_csr
        
        return get_block
    
    @staticmethod
    def parse(args, file_path: str, out_dir: Path, gene_db: MapGene, loom: LoomFile, result):
        """
        Parse MTX format files.
        """
        # Discover the triplet files
        matrix_path, barcodes_path, features_path = MtxHandler._discover_mtx_files(file_path)
        
        if matrix_path is None:
            ErrorJSON("No matrix.mtx file found in input")
        
        result["input_group"] = Path(matrix_path).name
        
        # Parse MTX header
        n_genes, n_cells, nnz, is_pattern = MtxHandler._parse_mtx_header(matrix_path)
        result["nber_rows"] = n_genes
        result["nber_cols"] = n_cells
        
        # Read cell barcodes
        if barcodes_path:
            cells = MtxHandler._read_barcodes(barcodes_path)
            if len(cells) != n_cells:
                ErrorJSON(f"Barcodes file has {len(cells)} entries but matrix has {n_cells} cells.")
        else:
            cells = [f"Cell_{i+1}" for i in range(n_cells)]
        
        # Read gene/feature information
        if features_path:
            gene_ids, gene_names = MtxHandler._read_features(features_path)
            if len(gene_ids) != n_genes:
                ErrorJSON(f"Features file has {len(gene_ids)} entries but matrix has {n_genes} genes.")
        else:
            gene_ids = [f"Gene_{i+1}" for i in range(n_genes)]
            gene_names = [f"Gene_{i+1}" for i in range(n_genes)]
        
        # Validate uniqueness of gene IDs (gene names can legitimately be duplicated)
        if len(set(gene_ids)) != len(gene_ids):
            ErrorJSON("Gene IDs are not unique in features file")
        if len(set(cells)) != len(cells):
            ErrorJSON("Cell barcodes are not unique in barcodes file")
        
        # Write gene and cell names + Chr/Biotypes info from DB
        parsed_genes, _ = loom.write_names_and_gene_db(cell_ids=cells, original_gene_names=gene_ids, gene_db=gene_db, gene_db_queries=gene_ids, output_dir=out_dir, result=result, n_cells=n_cells, n_genes=n_genes)
        
        # Write expression matrix
        get_block = MtxHandler._create_mtx_block_reader(matrix_path, n_genes, n_cells, nnz, is_pattern)
        stats = loom.write_expression_matrix(get_block=get_block, n_cells=n_cells, n_genes=n_genes, gene_metadata=parsed_genes, dest_path="/matrix")
        
        return stats
    
class TextHandler:
    @staticmethod
    def _decode_delim(delim: str) -> str:
        # Match preparse behavior: allow '\t', '\n', etc.
        d = bytes(delim, "utf-8").decode("unicode_escape")
        if len(d) != 1: ErrorJSON(f"Delimiter must be a single character after decoding. Got: {repr(d)}")
        return d

    @staticmethod
    def _normalize_gene_name(raw: str | None) -> str:
        if raw is None: return ""
        s = str(raw).strip()
        if s == "": return ""
        if "|" in s: s = s.split("|", 1)[0].strip()
        return s

    @staticmethod
    def _drop_fully_empty_rows_polars(df):
        """
        Drop rows that are completely empty (all fields are null/empty/whitespace).
        This makes text parsing robust to blank lines anywhere in the file.
        """
        as_str = [pl.col(c).cast(pl.Utf8, strict=False).fill_null("").str.strip_chars() for c in df.columns]
        empty_row = pl.all_horizontal([expr == "" for expr in as_str])
        return df.filter(~empty_row)

    @staticmethod
    def _scan_text_matrix(args, file_path: str) -> tuple[list[str], list[str], list[str], "np.ndarray"]:
        """
        Fast single-read path for RAW_TEXT
        """
        
        delim = TextHandler._decode_delim(args.delim)
        header = (args.header == "true")
        col_mode = args.col  # none|first|last

        if col_mode not in ("none", "first", "last"):
            ErrorJSON(f"Unknown --col value: {col_mode}")

        # Read everything as strings first (fast and robust). We cast numeric block in one shot.
        header_fields = None
        if header:
            try:
                with open(file_path, "r", encoding="utf-8", errors="strict") as f:
                    first_line = f.readline()
            except UnicodeDecodeError as e:
                ErrorJSON(f"File encoding error at byte {e.start}: {e.reason}. Try saving as UTF-8.")
            except Exception as e:
                ErrorJSON(f"Failed to read header line. {str(e)}")

            if not first_line:
                ErrorJSON("Input text file appears to be empty (no data rows).")

            first_line = first_line.rstrip("\r\n")
            header_fields = first_line.split(delim)

            # Drop trailing empty fields caused by trailing delimiter(s)
            while header_fields and header_fields[-1].strip() == "":
                header_fields.pop()
            
            # Remove quotes
            header_fields = [str(c).strip().strip('"') for c in header_fields]

        try:
            df = pl.read_csv(file_path, separator=delim, has_header=False, skip_rows=1 if header else 0, infer_schema_length=0, ignore_errors=False, try_parse_dates=False, quote_char='"')
        except Exception as e:
            ErrorJSON(f"Failed to read text file. {str(e)}")
        
        df = TextHandler._drop_fully_empty_rows_polars(df)

        if df.height == 0:
            ErrorJSON("Input text file contains no data rows (after removing empty lines).")
        
        if df.width == 0:
            ErrorJSON("Input text file contains no data cols (after removing empty lines).")

        # Header row -> cells
        if header:
            if header_fields is None:
                ErrorJSON("Internal error: missing header_fields.")
            header_cols = header_fields

            if col_mode == "none":
                # Header must be exactly cell names
                cells = [c.strip() if c is not None else "" for c in header_cols]
                cells = [(c if c != "" else f"Cell_{i+1}") for i, c in enumerate(cells)]
                num_df = df
                genes_raw = ["__unknown"] * df.height
                genes_norm = [f"Gene_{i+1}" for i in range(df.height)]
            else:
                if df.width < 2:
                    ErrorJSON("Data rows must have at least 2 columns when --col is first/last.")
                n_cells = df.width - 1

                # Accept either:
                #   - header has ONLY cells (len == n_cells), or
                #   - header includes a gene placeholder (len == n_cells+1)
                if len(header_cols) == n_cells:
                    cell_cols = header_cols
                elif len(header_cols) == n_cells + 1:
                    if col_mode == "first":
                        cell_cols = header_cols[1:]
                    else:
                        cell_cols = header_cols[:-1]
                else:
                    ErrorJSON(f"Header length mismatch: expected {n_cells} (cells only) or {n_cells+1} (with gene header), but got {len(header_cols)}. Check --delim/--col.")

                cells = [c.strip() if c is not None else "" for c in cell_cols]
                cells = [(c if c != "" else f"Cell_{i+1}") for i, c in enumerate(cells)]

                if col_mode == "first":
                    gene_series = df.select(df.columns[0]).to_series()
                    num_df = df.select(df.columns[1:])
                else:
                    gene_series = df.select(df.columns[-1]).to_series()
                    num_df = df.select(df.columns[:-1])

                g_raw = gene_series.cast(pl.Utf8).fill_null("").str.strip_chars().to_list()
                genes_raw = [(name if name != "" else f"Gene_{i+1}") for i, name in enumerate(g_raw)]
                genes_norm = []
                for i, raw in enumerate(genes_raw):
                    norm = TextHandler._normalize_gene_name(raw)
                    genes_norm.append(norm if norm != "" else f"Gene_{i+1}")
        else:
            # No header -> generate cell names
            if col_mode == "none":
                n_cells = df.width
                cells = [f"Cell_{i+1}" for i in range(n_cells)]
                num_df = df
                genes_raw = ["__unknown"] * df.height
                genes_norm = [f"Gene_{i+1}" for i in range(df.height)]
            else:
                if df.width < 2:
                    ErrorJSON("Data rows must have at least 2 columns when --col is first/last.")
                n_cells = df.width - 1
                cells = [f"Cell_{i+1}" for i in range(n_cells)]

                if col_mode == "first":
                    gene_series = df.select(df.columns[0]).to_series()
                    num_df = df.select(df.columns[1:])
                else:
                    gene_series = df.select(df.columns[-1]).to_series()
                    num_df = df.select(df.columns[:-1])

                g_raw = gene_series.cast(pl.Utf8).fill_null("").str.strip_chars().to_list()
                genes_raw = [(name if name != "" else f"Gene_{i+1}") for i, name in enumerate(g_raw)]
                genes_norm = []
                for i, raw in enumerate(genes_raw):
                    norm = TextHandler._normalize_gene_name(raw)
                    genes_norm.append(norm if norm != "" else f"Gene_{i+1}")

        # Convert numeric block to create_dataset in one vectorized step
        try:
            num_df = num_df.with_columns([pl.all().cast(pl.Float64)])
        except Exception as e:
            ErrorJSON(f"Non-numeric value encountered in matrix values: {str(e)}. Did you set --header/--delim/--col correctly?")

        # Ensure Genes x Cells orientation (polars returns 2D rows x cols already)
        n_genes = num_df.height
        n_cells = num_df.width
        if n_genes == 0:
            ErrorJSON("Parsed numeric matrix has 0 rows (genes).")
        if n_cells == 0:
            ErrorJSON("Parsed numeric matrix has 0 columns (cells).")
        if n_genes != len(genes_raw):
            ErrorJSON(f"Parsed numeric matrix has {n_genes} rows but {len(genes_raw)} gene names.")
        if n_cells != len(cells):
            ErrorJSON(f"Parsed numeric matrix has {n_cells} columns but {len(cells)} cell names.")

        return genes_raw, genes_norm, cells, num_df

    @staticmethod
    def parse(args, file_path: str, out_dir: Path, gene_db: MapGene, loom: LoomFile, result):
        result["input_group"] = "text_file"

        # Parse text into RAM
        genes_raw, genes_norm, cells, num_df = TextHandler._scan_text_matrix(args, file_path)
        n_genes = num_df.height
        n_cells = num_df.width
        result["nber_rows"] = n_genes
        result["nber_cols"] = n_cells

        # Validate identifiers (keep in handler)
        if len(set(genes_norm)) != len(genes_norm):
            ErrorJSON("Gene names (normalized) are not unique. Did you set --col correctly?")
        if len(set(cells)) != len(cells):
            ErrorJSON("Cell names are not unique (from header).")

        # Write gene and cell names + Chr/Biotypes infos from DB
        parsed_genes, _ = loom.write_names_and_gene_db(cell_ids=cells, original_gene_names=genes_raw, gene_db=gene_db, gene_db_queries=genes_norm, output_dir=out_dir, result=result, n_cells=n_cells, n_genes=n_genes)

        # Write expression using the shared core (cells x genes blocks)
        def get_block(start, end):
            # Polars slice: select columns (cells) from 'start' to 'end'. Then convert ONLY that chunk to numpy
            block = num_df.select(num_df.columns[start:end]).to_numpy()
            return block.T  # Transpose to (Cells x Genes) for LoomFile
        stats = loom.write_expression_matrix(get_block=get_block, n_cells=n_cells, n_genes=n_genes, gene_metadata=parsed_genes, dest_path="/matrix")

        return stats

## Error handling
class ErrorJSON(Exception):
    def __init__(self, message: str, output: str = None):
        # still call Exception init so tracebacks, etc. work if you ever raise()
        super().__init__(message)
        payload = {"displayed_error": message}

        if output:
            # write JSON to the given file
            with open(output, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)
        else:
            # or print it to stdout
            print(json.dumps(payload, ensure_ascii=False), file=sys.stdout)

        # then immediately exit with an error code
        sys.exit(1)

## Output Loom file handling
class LoomFile:
    def __init__(self, output_path: str):
        self.loomPath = Path(output_path)
        self.handle = h5py.File(self.loomPath, "w") # This automatically overwrites the file if it exists      
        self.ribo_protein_gene_names: set[str] = set()
        self._ensure_loom_v3_layout()

    def _ensure_loom_v3_layout(self) -> None:
        self.handle.require_group("attrs")
        self.handle.require_group("col_attrs")
        self.handle.require_group("row_attrs")
        self.handle.require_group("layers")
        self.handle.require_group("row_graphs")
        self.handle.require_group("col_graphs")
        self.handle["attrs"].create_dataset("LOOM_SPEC_VERSION", data="3.0.0", dtype=h5py.string_dtype(encoding="utf-8"))

    def close(self) -> None:
        if self.handle is not None:
            self.handle.close()
            self.handle = None

    def get_dataset_size(self, path: str) -> int:
        if path in self.handle: return self.handle[path].id.get_storage_size()
        return 0

    @staticmethod
    def is_mito(chr_name: str | None) -> bool:
        if chr_name is None: return False
        s = str(chr_name).strip()
        if not s: return False
        s_up = s.upper()
        if s_up in {"MT", "M", "MITOCHONDRION_GENOME", "DMEL_MITOCHONDRION_GENOME"}: return True
        s_up = s_up.replace("CHROMOSOME", "").replace("CHR", "").replace("_", "").replace("-", "").strip()
        if s_up in {"MT", "M"}: return True
        if "MITO" in s_up: return True
        return False

    def is_ribo(self, gene_name: str | None) -> bool:
        if not self.ribo_protein_gene_names or gene_name is None: return False
        if isinstance(gene_name, (bytes, np.bytes_)): 
            gene_name = gene_name.decode(errors="ignore")
        return str(gene_name).strip().upper() in self.ribo_protein_gene_names

    @staticmethod
    def is_protein_coding(biotype: str | None) -> bool:
        if biotype is None: return False
        s = str(biotype).strip()
        if not s: return False
        s_up = s.upper()
        return (s_up == "PROTEIN_CODING") or s_up.startswith("PROTEIN_CODING")

    def _coerce_for_h5(self, data: Any) -> tuple[np.ndarray, Any]:
        """
        Returns (np_array, dtype_override_or_None).
        Preserves dtypes from source: strings stay strings, numbers stay numbers.
        """
        arr = data if isinstance(data, np.ndarray) else np.array(data)

        # scalar
        if arr.ndim == 0:
            if isinstance(arr.item(), (bytes, str, np.bytes_, np.str_)):
                return np.array(arr.item()).astype(object), h5py.string_dtype("utf-8")
            return arr, None

        # strings or objects -> treat as strings (preserves string metadata from source)
        if arr.dtype.kind in ("U", "S", "O"):
            out = arr.astype(object)
            # Decode bytes if needed
            if arr.dtype.kind in ("S", "O"):
                flat = out.ravel()
                for i, v in enumerate(flat):
                    if isinstance(v, (bytes, np.bytes_)):
                        flat[i] = v.decode(errors="ignore")
            return out, h5py.string_dtype("utf-8")

        # numeric dtypes (int, float, bool, etc.)
        return arr, None

    def write_raw(self, data: Any, path: str, *, compression: bool = True) -> None:
        arr, dtype = self._coerce_for_h5(data)
        if path in self.handle:
            del self.handle[path]
        if arr.ndim == 0:
            self.handle.create_dataset(path, data=arr, dtype=dtype)
        else:
            self.handle.create_dataset(path, data=arr, dtype=dtype, compression=(LOOM_COMPRESSION if compression else None))

    def _orientation_from_path(self, path: str) -> str:
        if path.startswith("/col_attrs/"): return "CELL"
        if path.startswith("/row_attrs/"): return "GENE"
        if path == "/matrix" or path.startswith("/layers/"): return "EXPRESSION_MATRIX"
        if path.startswith("/attrs/"): return "GLOBAL"
        if path.startswith("/row_graphs/"): return "GENE"
        if path.startswith("/col_graphs/"): return "CELL"
        return "GLOBAL"

    def _infer_meta_dims(self, arr: np.ndarray, on: str, *, n_cells: int, n_genes: int) -> tuple[int, int]:
        if arr.ndim == 0: return (1, 1)
        if on == "CELL":
            if arr.ndim == 1: return (1, n_cells)
            r, c = int(arr.shape[0]), int(arr.shape[1])
            if r == n_cells: return (c, n_cells)
            if c == n_cells: return (r, n_cells)
            return (r, n_cells)
        if on == "GENE":
            if arr.ndim == 1: return (n_genes, 1)
            r, c = int(arr.shape[0]), int(arr.shape[1])
            if r == n_genes: return (n_genes, c)
            if c == n_genes: return (n_genes, r)
            return (n_genes, c)
        if on == "EXPRESSION_MATRIX":
            return (n_genes, n_cells)
        if arr.ndim == 1:
            return (int(arr.shape[0]), 1)
        return (int(arr.shape[0]), int(arr.shape[1]))

    def write_metadata(self, data: Any, path: str, *, n_cells: int, n_genes: int, imported: int, is_categorical: bool = None) -> Metadata:
        self.write_raw(data, path)

        on = self._orientation_from_path(path)
        arr = data if isinstance(data, np.ndarray) else np.array(data)
        missing = int(count_missing(arr)) if arr.ndim <= 1 else None

        is_numeric = False
        try:
            is_numeric = np.issubdtype(np.asarray(arr).dtype, np.number)
        except Exception:
            is_numeric = False

        nber_rows, nber_cols = self._infer_meta_dims(arr, on, n_cells=n_cells, n_genes=n_genes)

        m = Metadata(name=path, on=on if on in ("CELL", "GENE", "GLOBAL") else "EXPRESSION_MATRIX", nber_rows=int(nber_rows), nber_cols=int(nber_cols), missing_values=missing, dataset_size=int(self.get_dataset_size(path)), imported=int(imported))

        if on in ("CELL", "GENE", "GLOBAL") and arr.ndim <= 1:
            vals = [v.decode(errors="ignore") if isinstance(v, (bytes, np.bytes_)) else str(v) for v in arr.ravel()]
            counts = Counter(vals)
            m.distinct_values = len(counts)
            m.categories = dict(counts)
            m.finalize_type(is_numeric=is_numeric, is_categorical=is_categorical)
        else:
            m.type = "NUMERIC" if is_numeric else "STRING"

        return m

    def write_names_and_gene_db(self, *, cell_ids: list[str], original_gene_names: list[str], gene_db: MapGene, output_dir: Path, result: dict, n_cells: int, n_genes: int, gene_db_queries: list[str] | None = None) -> tuple[list[Gene], set[str]]:

        # Write cell + raw gene names
        result["metadata"].append(self.write_metadata(cell_ids, "/col_attrs/CellID", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(original_gene_names, "/row_attrs/Original_Gene", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))

        # Use normalized gene identifiers for DB lookup when provided
        queries = gene_db_queries if gene_db_queries is not None else original_gene_names
        parsed_genes, not_found_queries = gene_db.parse_genes_list(queries)
        result["nber_not_found_genes"] = int(len(not_found_queries))
        
        # Find Original name of queried genes that are not found
        if gene_db_queries is not None:
            not_found_idx = [i for i, g in enumerate(parsed_genes) if g.biotype == "__unknown"]
            not_found_genes = []
            for i in not_found_idx: not_found_genes.append(original_gene_names[i])
        else:
            not_found_genes = list(not_found_queries)
        
        # Write not found genes to file
        nf_path = output_dir / "not_found_genes.txt"
        with open(nf_path, "w", encoding="utf-8") as f_nfg:
            for g in not_found_genes:
                f_nfg.write(f"{g}\n")

        # DB-derived vectors
        ens_ids = [g.ensembl_id for g in parsed_genes]
        gene_names = [g.name for g in parsed_genes]
        biotypes = [g.biotype for g in parsed_genes]
        chroms = [g.chr for g in parsed_genes]
        sum_exon_length = [g.sum_exon_length for g in parsed_genes]

        result["metadata"].append(self.write_metadata(ens_ids, "/row_attrs/Accession", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(gene_names, "/row_attrs/Gene", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(gene_names, "/row_attrs/Name", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(biotypes, "/row_attrs/_Biotypes", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=True))
        result["metadata"].append(self.write_metadata(chroms, "/row_attrs/_Chromosomes", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=True))
        result["metadata"].append(self.write_metadata(sum_exon_length, "/row_attrs/_SumExonLength", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))

        return parsed_genes, set(not_found_genes)

    def write_stable_ids(self, *, n_cells: int, n_genes: int, result: dict) -> None:
        result["metadata"].append(self.write_metadata(list(range(n_genes)), "/row_attrs/_StableID", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(list(range(n_cells)), "/col_attrs/_StableID", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))

    def write_qc_vectors(self, *, stats: dict, n_cells: int, n_genes: int, result: dict) -> None:
        result["metadata"].append(self.write_metadata(stats["cell_depth"], "/col_attrs/_Depth", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(stats["cell_detected"], "/col_attrs/_Detected_Genes", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(stats["cell_mt"], "/col_attrs/_Mitochondrial_Content", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(stats["cell_rrna"], "/col_attrs/_Ribosomal_Content", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(stats["cell_prot"], "/col_attrs/_Protein_Coding_Content", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
        result["metadata"].append(self.write_metadata(stats["gene_sum"], "/row_attrs/_Sum", n_cells=n_cells, n_genes=n_genes, imported=0, is_categorical=False))
    
    def write_expression_matrix(self, *, get_block: callable, n_cells: int, n_genes: int, gene_metadata: list[Gene] | None, dest_path: str = "/matrix") -> dict:
        """
        Optimized writer: Handles both DENSE (numpy) and SPARSE (scipy) blocks.
        Calculates stats on sparse data (CSR) to avoid overhead, densifies only for the final write.
        """
        chunk_shape = (min(n_genes, LOOM_CHUNK_GENES), min(n_cells, LOOM_CHUNK_CELLS))       
        dset = self.handle.create_dataset(dest_path, shape=(n_genes, n_cells), dtype=LOOM_DTYPE, chunks=chunk_shape, compression=LOOM_COMPRESSION, compression_opts=LOOM_COMPRESSION_LEVEL)

        total_zeros = 0
        is_integer = True

        compute = gene_metadata is not None
        cell_depth = np.zeros(n_cells, dtype=np.float64) if compute else None
        cell_detected = np.zeros(n_cells, dtype=np.float64) if compute else None
        cell_mt = np.zeros(n_cells, dtype=np.float64) if compute else None
        cell_rrna = np.zeros(n_cells, dtype=np.float64) if compute else None
        cell_prot = np.zeros(n_cells, dtype=np.float64) if compute else None
        gene_sum = np.zeros(n_genes, dtype=np.float64) if compute else None

        if compute:
            mt_mask = np.array([self.is_mito(g.chr) for g in gene_metadata], dtype=bool)
            ribo_mask = np.array([self.is_ribo(g.name) for g in gene_metadata], dtype=bool)
            prot_mask = np.array([self.is_protein_coding(g.biotype) for g in gene_metadata], dtype=bool)

        for start in range(0, n_cells, DEFAULT_BLOCK_CELLS):
            end = min(start + DEFAULT_BLOCK_CELLS, n_cells)
            
            # 1. Get Block (Can be Dense or Sparse)
            block = get_block(start, end) 
            
            # 2. Fast Stats Calculation
            if sp.issparse(block):
                # SPARSE PATH (Faster)
                # Calculate stats on .data only (ignore zeros)
                total_zeros += (block.shape[0] * block.shape[1]) - block.nnz
                # Check integers only on non-zero elements
                if is_integer:
                    # Check if any non-zero element is not an integer. We assume structural zeros are integers (0), so we only check .data
                    if not np.all(np.floor(block.data) == block.data):
                        is_integer = False
                if compute:
                    # Sums on sparse matrices are much faster
                    cell_depth[start:end] = np.ravel(block.sum(axis=1))
                    cell_detected[start:end] = np.add.reduceat((block.data != 0), block.indptr[:-1]).astype(np.int64)

                    gene_sum += np.ravel(block.sum(axis=0))

                    if mt_mask.any(): cell_mt[start:end] = np.ravel(block[:, mt_mask].sum(axis=1))
                    if ribo_mask.any(): cell_rrna[start:end] = np.ravel(block[:, ribo_mask].sum(axis=1))
                    if prot_mask.any(): cell_prot[start:end] = np.ravel(block[:, prot_mask].sum(axis=1))

                # 3. Densify ONLY for writing
                dset[:, start:end] = block.T.toarray().astype(DEFAULT_NP_DTYPE, copy=False)

            else:
                # DENSE PATH
                chunk_cxg = np.asarray(block, dtype=DEFAULT_NP_DTYPE)
                total_zeros += int(chunk_cxg.size - np.count_nonzero(chunk_cxg))
                
                if is_integer and not np.all(np.floor(chunk_cxg) == chunk_cxg):
                    is_integer = False

                if compute:
                    cell_depth[start:end] = chunk_cxg.sum(axis=1)
                    cell_detected[start:end] = np.count_nonzero(chunk_cxg, axis=1)
                    gene_sum += chunk_cxg.sum(axis=0)

                    if mt_mask.any(): cell_mt[start:end] = chunk_cxg[:, mt_mask].sum(axis=1)
                    if ribo_mask.any(): cell_rrna[start:end] = chunk_cxg[:, ribo_mask].sum(axis=1)
                    if prot_mask.any(): cell_prot[start:end] = chunk_cxg[:, prot_mask].sum(axis=1)

                dset[:, start:end] = chunk_cxg.T

        def to_percentage(subset_sum, total_sum):
            if subset_sum is None or total_sum is None: return None
            return np.divide(subset_sum, total_sum, out=np.zeros_like(subset_sum), where=total_sum != 0) * 100

        stats = {
            "cell_depth": cell_depth.astype(DEFAULT_NP_DTYPE) if cell_depth is not None else None,
            "cell_detected": cell_detected.astype(DEFAULT_NP_DTYPE) if cell_detected is not None else None,
            "cell_mt": to_percentage(cell_mt, cell_depth).astype(DEFAULT_NP_DTYPE) if cell_mt is not None else None,
            "cell_rrna": to_percentage(cell_rrna, cell_depth).astype(DEFAULT_NP_DTYPE) if cell_rrna is not None else None,
            "cell_prot": to_percentage(cell_prot, cell_depth).astype(DEFAULT_NP_DTYPE) if cell_prot is not None else None,
            "gene_sum": gene_sum.astype(DEFAULT_NP_DTYPE) if gene_sum is not None else None,
            "total_zeros": int(total_zeros),
            "is_count_table": int(is_integer),
            "empty_cells": int(np.sum(cell_depth == 0)) if cell_depth is not None else None,
            "empty_genes": int(np.sum(gene_sum == 0)) if gene_sum is not None else None,
        }
        return stats

    @staticmethod
    def _reserved_paths() -> set[str]:
        # Everything that LoomFile.finalize() will write (computed metadata)
        return {"/attrs/LOOM_SPEC_VERSION", "/col_attrs/_Depth", "/col_attrs/_Detected_Genes", "/col_attrs/_Mitochondrial_Content", "/col_attrs/_Ribosomal_Content", "/col_attrs/_Protein_Coding_Content", "/row_attrs/_Sum", "/row_attrs/_StableID", "/col_attrs/_StableID"}

    def finalize(self, result, stats, n_cells, n_genes):
        self.write_qc_vectors(stats=stats, n_cells=n_cells, n_genes=n_genes, result=result)
        self.write_stable_ids(n_cells=n_cells, n_genes=n_genes, result=result)
        
        result["dataset_size"] = int(self.get_dataset_size("/matrix"))
        result["nber_zeros"] = int(stats["total_zeros"])
        result["empty_cols"] = int(stats["empty_cells"])
        result["empty_rows"] = int(stats["empty_genes"])
        result["is_count_table"] = int(stats["is_count_table"])
        return result

## DB Stuff
def count_missing(obj):
    if isinstance(obj, np.ndarray):
        flat = obj.ravel()
    else:
        flat = obj

    missing = 0
    for o in flat:
        if o is None:
            missing += 1
            continue
        if isinstance(o, (bytes, np.bytes_)):
            o = o.decode(errors="ignore")
        s = str(o)
        if s == "" or s.lower() in ("nan", "null"):
            missing += 1
    return missing

def dataclass_to_json(obj):
    if dataclasses.is_dataclass(obj):
        d = dataclasses.asdict(obj)
        return {
            k: dataclass_to_json(v) for k, v in d.items() 
            if v is not None and not (isinstance(v, (set, list, dict)) and len(v) == 0)
        }
    if isinstance(obj, dict):
        # Clean keys: Convert numpy/bool keys to strings
        return {str(k): dataclass_to_json(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple, set)):
        # Recursively clean lists/sets
        return [dataclass_to_json(x) for x in obj]
    if isinstance(obj, np.bool_):
        return bool(obj)
    if isinstance(obj, (np.integer, np.int64, np.int32)):
        return int(obj)
    if isinstance(obj, (np.floating, np.float64, np.float32)):
        return float(obj)
    if isinstance(obj, (np.str_, np.bytes_)):
        return str(obj)
    return obj

class DBManager:
    def __init__(self, *, dbname: str, user: str, password: str, host: str, port:int, connect_timeout: int = DEFAULT_CONNECT_TIMEOUT, sslmode: Optional[str] = None) -> None:
        self._base_conn_kwargs: Dict[str, Any] = {
            "dbname": dbname,
            "user": user,
            "password": password,
            "port": port,
            "connect_timeout": connect_timeout,
            "host": host
        }
        if sslmode is not None:
            self._base_conn_kwargs["sslmode"] = sslmode
        self._conn: Optional[PGConnection] = None
        self.map_gene = MapGene()
    
    def connect(self) -> None:
        if self._conn is not None:
            try:
                # Test if connection is alive
                self._conn.cursor().execute('SELECT 1')
                return
            except (psycopg2.OperationalError, psycopg2.InterfaceError):
                self._conn = None
        
        try:
            self._conn = psycopg2.connect(**self._base_conn_kwargs)
        except Exception as e:
            ErrorJSON(f"Failed to connect to PostgreSQL: {e}")

    def disconnect(self) -> None:
        if self._conn is None:
            return
        try:
            self._conn.close()
        finally:
            self._conn = None

    @contextmanager
    def _cursor(self):
        if self._conn is None or self._conn.closed:
            ErrorJSON("Not connected. Call connect() first (or use get_genes_in_db_once).")
        cur = self._conn.cursor(cursor_factory=RealDictCursor)
        try:
            yield cur
        finally:
            cur.close()

    def get_genes_in_db(self, organism_id: int) -> MapGene:
        self.map_gene.init()

        sql = """
            SELECT ensembl_id, name, biotype, chr, gene_length, sum_exon_length, latest_ensembl_release, alt_names, obsolete_alt_names
            FROM genes
            WHERE organism_id = %s
        """

        with self._cursor() as cur:
            cur.execute(sql, (organism_id,))
            rows = cur.fetchall()

        for r in rows:
            g = Gene(
                ensembl_id=r.get("ensembl_id"),
                name=r.get("name"),
                biotype=r.get("biotype"),
                chr=r.get("chr"),
                gene_length=int(r.get("gene_length") or 0),
                sum_exon_length=int(r.get("sum_exon_length") or 0),
                latest_ensembl_release=int(r.get("latest_ensembl_release") or 0),
            )

            # By ensembl_id
            if g.ensembl_id:
                key = g.ensembl_id.upper()
                self.map_gene.ensembl_db.setdefault(key, []).append(g)

            # By gene name
            if g.name:
                key = g.name.upper()
                self.map_gene.gene_db.setdefault(key, []).append(g)

            # alt_names (comma-separated string)
            alt_names_raw = r.get("alt_names") or ""
            for token in (t.strip() for t in alt_names_raw.split(",") if t.strip()):
                token_up = token.upper()
                g.alt_names.add(token_up)
                self.map_gene.alt_db.setdefault(token_up, []).append(g)

            # obsolete_alt_names (comma-separated string)
            obsolete_raw = r.get("obsolete_alt_names") or ""
            for token in (t.strip() for t in obsolete_raw.split(",") if t.strip()):
                token_up = token.upper()
                g.obsolete_alt_names.add(token_up)
                self.map_gene.obsolete_db.setdefault(token_up, []).append(g)

        return self.map_gene

    def get_genes_in_db_once(self, organism_id: int) -> MapGene:
        self.connect()
        try:
            return self.get_genes_in_db(organism_id)
        finally:
            self.disconnect()

    def get_ribo_protein_gene_names(self, organism_id: int, go_term: str = DEFAULT_RIBO_GO_TERM) -> set[str]:
        """
        Returns a set of gene symbols (genes.name) for the GO term.
        Uses gene_set_items.identifier (NOT gene_sets.identifier).
        """
        sql = """
        WITH target_set AS (
          SELECT
            gs.organism_id,
            gsi.gene_set_id,
            gsi.content
          FROM gene_set_items gsi
          JOIN gene_sets gs ON gs.id = gsi.gene_set_id
          WHERE gsi.identifier = %s
            AND gs.organism_id = %s
        )
        SELECT
          string_agg(DISTINCT g.name, ',' ORDER BY g.name) AS gene_names
        FROM target_set ts
        CROSS JOIN LATERAL unnest(string_to_array(ts.content, ',')) AS gene_id_text
        JOIN genes g ON g.id = (gene_id_text)::integer;
        """
    
        with self._cursor() as cur:
            cur.execute(sql, (go_term, organism_id))
            row = cur.fetchone() or {}
    
        names_csv = row.get("gene_names") or ""
        names = {n.strip() for n in names_csv.split(",") if n and n.strip()}
        
        return {n.upper() for n in names}

    def get_ribo_protein_gene_names_once(self, organism_id: int, go_term: str = DEFAULT_RIBO_GO_TERM) -> set[str]:
        self.connect()
        try:
            return self.get_ribo_protein_gene_names(organism_id, go_term=go_term)
        finally:
            self.disconnect()

## Data class
@dataclass
class Metadata:
    name: str = None
    on: str = None
    type: str = None
    nber_cols: int = 0
    nber_rows: int = 0
    dataset_size: int = 0
    distinct_values: int = None
    missing_values: int = None
    nber_zeros: int = None
    is_count_table: int = None
    imported: int = 0
    categories: Dict[str, int] = field(default_factory=dict) # Changed from Set to Dict
    
    def is_categorical(self) -> bool:
        # single value: 1x1 (or 1 element total) -> never categorical
        if self.nber_rows * self.nber_cols <= 1:
            return False
        
        n_unique = len(self.categories)
        if n_unique == 0: return False
        if n_unique > CATEGORICAL_NMAX: return False
        if n_unique < CATEGORICAL_NMIN: return True
            
        # Determine the denominator based on the orientation
        if self.on == "CELL":
            denominator = self.nber_cols
        elif self.on == "GENE":
            denominator = self.nber_rows
        else: 
            return n_unique < CATEGORICAL_NMIN

        if denominator == 0: return False
        
        # Threshold: unique values < xx% of the relevant dimension
        return n_unique <= (denominator * CATEGORICAL_PC_UNIQUE)

    def finalize_type(self, is_numeric: bool, is_categorical: bool = None):
        """Sets the final type and clears categories if not categorical."""
        if is_categorical is None: # If not, then I take it as is
            is_categorical = self.is_categorical() # Assess if categorical (a bit arbitrary)
        if is_categorical: 
            self.type = "DISCRETE"
        else:
            self.categories = {} # Clear counts if it's just a long list of unique strings
            self.type = "NUMERIC" if is_numeric else "STRING"

@dataclass
class Gene:
    ensembl_id: Optional[str] = None
    name: Optional[str] = None
    biotype: Optional[str] = None
    chr: Optional[str] = None
    gene_length: int = 0
    sum_exon_length: int = 0
    latest_ensembl_release: int = 0
    alt_names: Set[str] = field(default_factory=set)
    obsolete_alt_names: Set[str] = field(default_factory=set)

@dataclass
class MapGene:
    ensembl_db: Dict[str, List[Gene]] = field(default_factory=dict)
    gene_db: Dict[str, List[Gene]] = field(default_factory=dict)
    alt_db: Dict[str, List[Gene]] = field(default_factory=dict)
    obsolete_db: Dict[str, List[Gene]] = field(default_factory=dict)
    
    # Pre-compile regex pattern for version stripping (used in gene lookups)
    _VERSION_PATTERN = re.compile(r"\.\d+$")
    
    def init(self) -> None:
        self.ensembl_db.clear()
        self.gene_db.clear()
        self.alt_db.clear()
        self.obsolete_db.clear()

    @staticmethod
    def retrieve_latest(db_hits: List[Gene]) -> Gene:
        """ Finds the gene with the highest Ensembl release version. """
        if not db_hits:
            return None
        # Sorts by latest_ensembl_release descending and takes the first
        return sorted(db_hits, key=lambda g: g.latest_ensembl_release, reverse=True)[0]

    def parse_gene(self, query: str, index: int) -> Gene:
        """ Translates a query string into a Gene object using the MapGene DB. """
        # 1. Clean the input
        if not query or query.strip() == "":
            query = None
        
        db_hit = None
        
        if query:
            q_up = query.upper()
            
            # Waterfall search with optimized chained lookups
            db_hit = (
                self.ensembl_db.get(q_up) or
                self.ensembl_db.get(self._VERSION_PATTERN.sub("", q_up)) or
                self.gene_db.get(q_up) or
                self.alt_db.get(q_up) or
                self.obsolete_db.get(q_up)
            )
    
        # If found in DB
        if db_hit:
            g_hit = self.retrieve_latest(db_hit)
            # Ensure name is not null
            if not g_hit.name:
                g_hit.name = g_hit.ensembl_id
            return g_hit
    
        # If NOT found (Create fallback)
        fallback_name = query if query else f"Gene_{index + 1}"
        
        return Gene(ensembl_id="__unknown", name=fallback_name, biotype="__unknown", chr="__unknown", sum_exon_length=0, alt_names=set())

    def parse_genes_list(self, queries: List[str]):
        """ Process a list of gene identifiers (e.g. var_genes)  and returns a list of Gene objects. """
        results = []
        not_found_genes = []
        for i, q in enumerate(queries):
            gene_obj = self.parse_gene(q, i)
            if gene_obj.biotype == "__unknown":
                not_found_genes.append(q)
            results.append(gene_obj)
        return results, not_found_genes

## MAIN functions

# Dispatch table to run appropriate parsing function depending on filetype
dispatch = {
    'H5_10X': H510xHandler.parse,
    'H5AD': H5ADHandler.parse,
    'LOOM': LoomHandler.parse,
    'RDS': RdsHandler.parse,
    'MTX': MtxHandler.parse,
    'RAW_TEXT': TextHandler.parse,
}

def get_env(name: str, required: bool = False, default: str | None = None) -> str | None:
    value = os.getenv(name, default)
    if required and not value:
        ErrorJSON(f"Missing required environment variable: {name}")
    return value

def parse_host_string(s: str):
    if "://" not in s: s = "postgresql://" + s
    u = urlparse(s)
    # host
    if not u.hostname:
        ErrorJSON("Missing host")
    host = u.hostname

    # port
    port = None
    if u.netloc:
        parts = u.netloc.split(":")
        if len(parts) == 2:
            if parts[1].isdigit():
                port = int(parts[1])
            else:
               ErrorJSON(f"Invalid port: {parts[1]!r}")
    if port is None:
        #ErrorJSON("Missing port in --dburl (expected HOST:PORT/DB)")
        port = DEFAULT_DB_PORT # default
    
    # dbname
    dbname = u.path.lstrip("/")
    if not dbname:
        ErrorJSON("Missing dbname")

    return host, port, dbname

# Main parsing method, called by "Main" and redispatching to correct format parsing method
def parse(args):
    # Find user/password from environment variables
    user_env = get_env("POSTGRES_USER", required=True)
    pass_env = get_env("POSTGRES_PASSWORD", required=True)
   
    # Extract informations from args.dburl
    host, port, dbname = parse_host_string(args.dburl)
    
    # Connect to DB
    db = DBManager(host=host, dbname=dbname, port=port, user=user_env, password=pass_env)
    
    # Extract genes from species
    gene_db = db.get_genes_in_db_once(args.organism)

    # Fetch ribosomal protein gene symbols via GO and attach to gene_db object
    ribo_set = db.get_ribo_protein_gene_names_once(args.organism, go_term=DEFAULT_RIBO_GO_TERM)

    # Create result dict
    result = {"detected_format": args.filetype, "input_path": args.f, "input_group": "", "output_path": args.output_path, "nber_rows": -1, "nber_cols": -1, "nber_not_found_genes": -1, "nber_zeros": -1, "is_count_table": -1, "empty_cols": -1, "empty_rows": -1, "dataset_size": -1, "metadata": [], "warnings": []}

    # Create Loom file
    loom = None
    try:
        loom = LoomFile(args.output_path)
        
        # Attach ribo set
        loom.ribo_protein_gene_names = ribo_set
        if not ribo_set:
            result["warnings"].append(f"No ribosomal protein genes found for {DEFAULT_RIBO_GO_TERM} (organism_id={args.organism}). Ribosomal protein content will be reported as 0 for all cells.")
         
        # Output directory
        out_dir = Path(args.output_path).parent

        # Call the appropriate parsing function to write loom and generate stats
        handler = dispatch.get(args.filetype)
        if handler:
            stats = handler(args, args.f, out_dir, gene_db, loom, result)
        else:
            ErrorJSON(f"Unknown file type: {args.filetype}")
        
        # Finalize by writing stats
        loom.finalize(result, stats, result["nber_cols"], result["nber_rows"])
    finally:
        if loom is not None: loom.close()
    
    # Clean empty warnings
    if "warnings" in result and not result["warnings"]:
        del result["warnings"]
    
    # Build JSON and write to output
    json_str = json.dumps(result, default=dataclass_to_json, ensure_ascii=False)
    if args.o:
        with open(os.path.join(args.o, "output.json"), "w", encoding="utf-8") as out:
            out.write(json_str)
    else:
        print(json_str)

# Validation method for organism argument
def positive_int(value):
    try:
        ivalue = int(value)
    except ValueError:
        ErrorJSON(f"--organism must be a positive integer and {value!r} is not an integer")
    if ivalue < 0:
        ErrorJSON("--organism must be a positive integer")
    return ivalue

## Helping text for default calling
custom_help = """
Parsing Mode

Options:
  -f %s             File to parse.
  -o %s             Output folder.
  --filetype %s     File type [RAW_TEXT, LOOM, H5_10x, H5AD, RDS, MTX]
  --header %s       The file has a header [true, false] (default: true).
  --col %s          Name Column [none, first, last] (default: first).
  --sel %s          Name of entry to load from archive or HDF5 (if multiple groups).
  --delim %s        Delimiter (default: tab).
  --organism %i     ID of the organism.
  --dburl %s        DB URL (format HOST:PORT/DB)
  --help            Show this help message and exit.
"""

def main():
    if '--help' in sys.argv:
        print(custom_help)
        sys.exit(0)

    parser = argparse.ArgumentParser(description='Parsing Mode Script', add_help=False)
    parser.add_argument('-f', metavar='File to parse', required=True)
    parser.add_argument('-o', metavar='Output folder', required=False)
    parser.add_argument('--filetype', metavar='File type', choices=['H5_10X', 'H5AD', 'LOOM', 'RDS', 'MTX', 'RAW_TEXT'], required=True)
    parser.add_argument('--header', metavar='[RAW_TEXT] Is there a header', choices=['true', 'false'], default='true', required=False)
    parser.add_argument('--col', metavar='[RAW_TEXT] Which column contains row names', choices=['none', 'first', 'last'], default='first', required=False)
    parser.add_argument('--sel', metavar='In case of multiple matrices, which one to use', default=None, required=False)
    parser.add_argument('--delim', metavar='[RAW_TEXT] Delimiter to parse columns', default=DEFAULT_TEXT_DELIM, required=False)
    parser.add_argument('--organism', metavar='Organism', type=positive_int, required=True)
    parser.add_argument('--dburl', metavar='Host URL for DB (format HOST:PORT/DB)', default=None, required=True)

    args = parser.parse_args()

    input_path = Path(args.f).resolve()
    if not input_path.is_file():
        ErrorJSON(f"Input file not found: {args.f}")
    # Determine the output directory
    output_dir = Path(args.o).resolve() if args.o else input_path.parent
    # Ensure the directory exists (handles both cases)
    output_dir.mkdir(parents=True, exist_ok=True) 
    # Set the final file path
    args.output_path = str(output_dir / LOOM_FILENAME)
    
    parse(args)

if __name__ == '__main__':
    main()