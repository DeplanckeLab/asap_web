#!/usr/bin/env python3
"""Build a snippet JSON from a full minimal extract (truncates long vectors)."""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

DEFAULT_MAX_VECTOR_LENGTH = 500


def truncate_list(values: list, limit: int) -> list:
    if len(values) <= limit:
        return values
    return values[:limit]


def truncate_obs(obs: dict, limit: int) -> dict:
    if not obs or "columns" not in obs:
        return obs
    out = copy.deepcopy(obs)
    for col in out["columns"].values():
        distinct = col.get("distinct_values")
        if isinstance(distinct, list):
            col["distinct_values"] = truncate_list(distinct, limit)
    return out


def truncate_var(var: dict, limit: int) -> dict:
    if not var:
        return var
    out: dict = {}
    if "index" in var:
        out["index"] = {
            "per_feature_values": truncate_list(
                var["index"]["per_feature_values"], limit
            )
        }
    if "columns" in var:
        out["columns"] = {}
        for name, col in var["columns"].items():
            out["columns"][name] = {
                "per_feature_values": truncate_list(
                    col["per_feature_values"], limit
                )
            }
    return out


def build_snippet(extract: dict, limit: int) -> dict:
    snippet = copy.deepcopy(extract)
    if "obs" in snippet:
        snippet["obs"] = truncate_obs(snippet["obs"], limit)
    if "var" in snippet:
        snippet["var"] = truncate_var(snippet["var"], limit)
    return snippet


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Full extract JSON path")
    parser.add_argument("output", type=Path, help="Snippet JSON output path")
    parser.add_argument(
        "--max-vector-length",
        type=int,
        default=DEFAULT_MAX_VECTOR_LENGTH,
        help=f"Max list length for var vectors and obs distinct_values (default: {DEFAULT_MAX_VECTOR_LENGTH})",
    )
    args = parser.parse_args()

    with args.input.open() as f:
        extract = json.load(f)

    snippet = build_snippet(extract, args.max_vector_length)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as f:
        json.dump(snippet, f, indent=2)
        f.write("\n")

    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
