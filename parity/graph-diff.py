#!/usr/bin/env python3
# graph-diff.py — structural diff of two normalized Render Graph JSONs.
#
# Compares the C# live-compiler graph (candidate) against the reference export-graph.mjs
# oracle. The C# normalized form is meant to be byte-identical to the reference (see
# docs/GRAPH-JSON-SCHEMA.md); this is the automated check. Exits 0 when they match
# (0 deltas), 1 otherwise, printing each delta.
#
# The top-level `id` (a per-instance random hash) and `source` (the DSL text, identical
# by construction) are ignored by default.
#
# Usage: python3 graph-diff.py <reference.json> <candidate.json> [--name NAME] [--ignore k,k]

import argparse
import json
import sys


def deepcmp(a, b, path, out):
    if type(a) is not type(b):
        out.append(f"{path}: type ref={type(a).__name__} cand={type(b).__name__}")
        return
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"{path}.{k}: only in candidate")
            elif k not in b:
                out.append(f"{path}.{k}: only in reference")
            else:
                deepcmp(a[k], b[k], f"{path}.{k}", out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(f"{path}: length ref={len(a)} cand={len(b)}")
            return
        for i, (x, y) in enumerate(zip(a, b)):
            deepcmp(x, y, f"{path}[{i}]", out)
    elif a != b:
        out.append(f"{path}: ref={a!r} cand={b!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("candidate")
    ap.add_argument("--name", default="")
    ap.add_argument("--ignore", default="id,source",
                    help="comma-separated top-level keys to ignore (default: id,source)")
    args = ap.parse_args()
    name = args.name or args.candidate

    try:
        ref = json.load(open(args.reference))
    except (OSError, ValueError) as e:
        print(f"[FAIL] {name}: cannot read reference graph ({e})")
        sys.exit(1)
    try:
        cand = json.load(open(args.candidate))
    except (OSError, ValueError) as e:
        # Most common cause: the C# compiler failed/skip-ed this program (NM-GRAPH-FAIL),
        # so no candidate graph was written.
        print(f"[FAIL] {name}: no candidate graph ({e}) — C# compile likely failed")
        sys.exit(1)

    ignore = {x for x in args.ignore.split(",") if x}
    out = []
    for k in sorted(set(ref) | set(cand)):
        if k in ignore:
            continue
        if k not in ref:
            out.append(f"{k}: only in candidate")
        elif k not in cand:
            out.append(f"{k}: only in reference")
        else:
            deepcmp(ref[k], cand[k], k, out)

    if out:
        print(f"[FAIL] {name}: {len(out)} graph delta(s)")
        for d in out[:40]:
            print("   " + d)
        if len(out) > 40:
            print(f"   … +{len(out) - 40} more")
        sys.exit(1)
    print(f"[PASS] {name}: graph byte-clean (0 deltas)")
    sys.exit(0)


if __name__ == "__main__":
    main()
