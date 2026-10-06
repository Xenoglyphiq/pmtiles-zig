#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml", "jsonschema"]
# ///
"""Validate a capability folder against the library standard.

Usage:  uv run .kit/validate.py <library-repo-dir>      (inside a library repo)
        uv run public/validate.py <library-repo-dir>   (from the standard repo)
        (or `pip install pyyaml jsonschema` and run with python)

Checks:
  1. spec/capability.yaml matches schemas/capability.schema.json
  2. conformance/manifest.json matches schemas/fixture.schema.json
  3. Cross-references: type refs resolve, operation error codes and limits exist,
     fixture ops / levels / error codes exist, case ids are unique, fixture files exist,
     capability id and spec_version match between the two files.
Exit code 0 = valid, 1 = problems found.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit("Missing dependencies: pip install pyyaml jsonschema")

BUILTIN = {"bool", "i32", "i64", "u8", "u32", "u64", "f32", "f64", "string", "bytes",
           "bytes_view", "timestamp", "duration", "lonlat", "bbox", "void"}


def schema_errors(instance, schema_path: Path, label: str) -> list[str]:
    schema = json.loads(schema_path.read_text())
    v = Draft202012Validator(schema)
    return [f"{label}: {'/'.join(map(str, e.absolute_path)) or '<root>'}: {e.message}"
            for e in sorted(v.iter_errors(instance), key=lambda e: list(map(str, e.absolute_path)))]


def type_names_in(ref: str) -> list[str]:
    """Pull every type name out of a type reference like optional<list<Entry>>."""
    return re.findall(r"[A-Za-z_][A-Za-z0-9_]*", ref.replace("map<string", "map<"))


def check_capability(cap: dict) -> list[str]:
    errs = []
    defined = {t["name"] for t in cap.get("types", [])}
    known = BUILTIN | defined | {"list", "optional", "map", "ordered_map"}
    codes = {e["code"] for e in cap.get("errors", [])}
    limits = {l["name"] for l in cap.get("limits", [])}
    prefix = cap["id"] + "."

    for e in cap.get("errors", []):
        if not e["code"].startswith(prefix):
            errs.append(f"error code {e['code']!r} should start with {prefix!r}")

    def check_ref(ref, where):
        for name in type_names_in(ref):
            if name not in known:
                errs.append(f"{where}: unknown type {name!r}")

    for t in cap.get("types", []):
        for f in t.get("fields", []):
            check_ref(f["type"], f"type {t['name']}.{f['name']}")
    names = [o["name"] for o in cap.get("operations", [])]
    for dup in {n for n in names if names.count(n) > 1}:
        errs.append(f"duplicate operation {dup!r}")
    for op in cap.get("operations", []):
        where = f"operation {op['name']}"
        check_ref(op["output"], where + " output")
        for f in op.get("inputs", []) + op.get("options", []):
            check_ref(f["type"], f"{where} input {f['name']}")
        for c in op.get("errors", []):
            if c not in codes:
                errs.append(f"{where}: error {c!r} not declared in errors")
        for l in op.get("uses_limits", []):
            if l not in limits:
                errs.append(f"{where}: limit {l!r} not declared in limits")
        if op["layer"] == "core":
            io_codes = [c for c in op.get("errors", [])
                        if next((e for e in cap["errors"] if e["code"] == c), {}).get("kind") == "io"]
            if io_codes:
                errs.append(f"{where}: core operations must not raise io errors ({', '.join(io_codes)})")
    return errs


def check_fixtures(cap: dict, man: dict, cases_dir: Path) -> list[str]:
    errs = []
    if man["capability"] != cap["id"]:
        errs.append(f"manifest capability {man['capability']!r} != {cap['id']!r}")
    if man["spec_version"] != cap["spec_version"]:
        errs.append(f"manifest spec_version {man['spec_version']} != capability {cap['spec_version']} (regenerate fixtures)")
    ops = {o["name"]: o for o in cap["operations"]}
    codes = {e["code"]: e["kind"] for e in cap["errors"]}
    levels = set(cap["conformance"]["levels"])
    seen = set()
    for c in man["cases"]:
        where = f"case {c['id']}"
        if c["id"] in seen:
            errs.append(f"{where}: duplicate id")
        seen.add(c["id"])
        if c["op"] not in ops:
            errs.append(f"{where}: unknown op {c['op']!r}")
        if c["level"] not in levels:
            errs.append(f"{where}: level {c['level']!r} not in capability levels {sorted(levels)}")
        err = c["expect"].get("error") if isinstance(c["expect"], dict) else None
        if err:
            if err["code"] not in codes:
                errs.append(f"{where}: error code {err['code']!r} not declared")
            elif codes[err["code"]] != err["kind"]:
                errs.append(f"{where}: kind {err['kind']!r} doesn't match declared {codes[err['code']]!r}")
            elif c["op"] in ops and err["code"] not in ops[c["op"]]["errors"]:
                errs.append(f"{where}: {err['code']!r} isn't listed in {c['op']}'s errors")
        for part in ("input", "expect"):
            p = c[part]
            if isinstance(p, dict) and "file" in p and not (cases_dir / p["file"]).is_file():
                errs.append(f"{where}: missing file cases/{p['file']}")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("capability_dir", type=Path)
    ap.add_argument("--kit", type=Path, default=Path(__file__).resolve().parent,
                    help="folder holding schemas/ (defaults to this script's folder)")
    a = ap.parse_args()

    cap_path = a.capability_dir / "spec" / "capability.yaml"
    man_path = a.capability_dir / "conformance" / "manifest.json"
    problems: list[str] = []

    cap = yaml.safe_load(cap_path.read_text())
    problems += schema_errors(cap, a.kit / "schemas" / "capability.schema.json", "capability.yaml")
    if not problems:
        problems += check_capability(cap)

    if man_path.exists():
        man = json.loads(man_path.read_text())
        s_errs = schema_errors(man, a.kit / "schemas" / "fixture.schema.json", "manifest.json")
        problems += s_errs
        if not s_errs and not problems:
            problems += check_fixtures(cap, man, a.capability_dir / "conformance" / "cases")
        n_cases = len(man.get("cases", []))
    else:
        problems.append("conformance/manifest.json not found (generate fixtures before writing ports)")
        n_cases = 0

    if problems:
        print(f"✗ {cap.get('id', '?')}: {len(problems)} problem(s)")
        for p in problems:
            print("  -", p)
        return 1
    print(f"✓ {cap['id']} spec {cap['spec_version']}: {len(cap['operations'])} operations, "
          f"{len(cap['errors'])} error codes, {n_cases} fixture cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
