#!/usr/bin/env python3
"""
Stream a pg_dump plain-format SQL file and print id, key, version_id from the
public.projects COPY ... FROM stdin; block.

Does not load the whole file into memory. One full pass of the dump is required
until the projects COPY section is found (often late in large dumps).

Usage:
  python3 scripts/extract_project_version_ids_from_dump.py /path/to/dump.sql
  python3 scripts/extract_project_version_ids_from_dump.py --help

Output: CSV to stdout with header: id,key,version_id
  NULL version_id is emitted as empty field between commas.

Limitation: rows are split on tab. If a projects column contains a literal tab
or an embedded newline as stored by pg_dump, this row may be mis-parsed. That
is uncommon for these columns in typical ASAP dumps.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from typing import List, Optional, Tuple


COPY_RE = re.compile(
    r"^COPY\s+(?:(?P<schema>[\w.]+)\.)?projects\s*\((?P<cols>[^)]+)\)\s+FROM\s+stdin\s*;\s*$",
    re.IGNORECASE,
)


def parse_copy_header(line: str) -> Optional[Tuple[str, List[str]]]:
    m = COPY_RE.match(line.strip())
    if not m:
        return None
    raw = m.group("cols")
    parts = [c.strip().strip('"') for c in raw.split(",")]
    return m.group("schema") or "public", parts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "dump_path",
        nargs="?",
        default="/data/dumps/2026_05_06_asap_production3.sql",
        help="Path to pg_dump plain SQL file (default: %(default)s)",
    )
    ap.add_argument(
        "--delimiter",
        choices=("comma", "tab"),
        default="comma",
        help="Output delimiter (default: comma CSV)",
    )
    args = ap.parse_args()
    path = args.dump_path

    delim = "\t" if args.delimiter == "tab" else ","
    quoting = csv.QUOTE_MINIMAL if args.delimiter == "comma" else csv.QUOTE_NONE

    try:
        f = open(path, "r", encoding="utf-8", errors="replace", newline="")
    except OSError as e:
        print(f"error: cannot open {path!r}: {e}", file=sys.stderr)
        return 1

    col_id = col_key = col_version = None
    cols: List[str] = []
    in_copy = False
    line_no = 0
    out_rows = 0
    warn_mismatch = 0

    writer = csv.writer(sys.stdout, delimiter=delim, lineterminator="\n", quoting=quoting)
    writer.writerow(["id", "key", "version_id"])

    with f:
        for line in f:
            line_no += 1
            if line_no % 500_000 == 0:
                print(f"... scanned {line_no} lines (projects rows written: {out_rows})", file=sys.stderr)

            if not in_copy:
                parsed = parse_copy_header(line)
                if parsed:
                    _, cols = parsed
                    try:
                        col_id = cols.index("id")
                        col_key = cols.index("key")
                        col_version = cols.index("version_id")
                    except ValueError as e:
                        print(f"error: COPY projects missing column: {e}", file=sys.stderr)
                        return 1
                    in_copy = True
                continue

            if line.startswith("\\."):
                break

            row = line.rstrip("\n\r").split("\t")
            if len(row) != len(cols):
                warn_mismatch += 1
                if warn_mismatch <= 5:
                    print(
                        f"warning: line {line_no} field count {len(row)} != {len(cols)}; skip",
                        file=sys.stderr,
                    )
                continue

            def field(i: int) -> str:
                v = row[i]
                if v == r"\N":
                    return ""
                return v

            try:
                pid = field(col_id)
                pkey = field(col_key)
                pver = field(col_version)
            except IndexError:
                warn_mismatch += 1
                continue

            writer.writerow([pid, pkey, pver])
            out_rows += 1

    if not in_copy:
        print("error: no COPY projects ... FROM stdin; block found", file=sys.stderr)
        return 1

    print(f"done: lines_read={line_no} projects_rows={out_rows} skipped_bad_width={warn_mismatch}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
