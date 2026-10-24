#!/usr/bin/env python3
"""Regenerate src/lib/protocol/effects.ts from the tables in docs/protocol/*.tsv."""
import json, os

DOCS = "docs/protocol"
OUT = "src/lib/protocol/effects.ts"
SWIFT_OUT = "Sources/LEDUnionCore/EffectTables.swift"


def tsv(fname, cols):
    rows = []
    for line in open(os.path.join(DOCS, fname)):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < len(cols):
            continue
        rows.append(dict(zip(cols, parts)))
    return rows


def main():
    tables = [
        ("melk", [{"id": int(r["id"]), "group": r["group"], "name": r["name"]}
                  for r in tsv("melk_effects.tsv", ["id", "group", "name"])]),
        ("elk", [{"id": int(r["id"]), "name": r["name"]}
                 for r in tsv("elk_effects.tsv", ["id", "name"])]),
        ("ledble", [{"id": int(r["id"]), "name": r["name"]}
                    for r in tsv("ble_mode.tsv", ["id", "name"])]),
        ("ledcar", [{"id": int(r["id"]), "name": r["name"]}
                    for r in tsv("car_mode.tsv", ["id", "name"])]),
        ("leddmx", [{"id": int(r["id"]), "name": r["name"]}
                    for r in tsv("dmx_model.tsv", ["id", "name"])]),
        ("ledlike", [{"id": int(r["id"]), "name": r["name"]}
                     for r in tsv("like_mode.tsv", ["id", "name"])]),
        ("ledpho", [{"id": int(r["id"]), "name": r["name"]}
                    for r in tsv("pho_mode.tsv", ["id", "name"])]),
        # Addressable-strip wiring options, not effects, but the same id/name shape.
        ("rgbOrders", [{"id": int(r["id"]), "name": r["name"]}
                       for r in tsv("rgb_order.tsv", ["id", "name"])]),
        ("rgbOrdersDmx02", [{"id": int(r["id"]), "name": r["name"]}
                            for r in tsv("rgb_order_dmx02.tsv", ["id", "name"])]),
    ]
    with open(OUT, "w") as fh:
        fh.write("// GENERATED from docs/protocol/*.tsv by tools/gen-effects.py"
                 " — do not edit by hand.\n")
        fh.write("import type { Effect } from './types'\n\n")
        for name, rows in tables:
            fh.write(f"export const {name}: Effect[] = [\n")
            for r in rows:
                fh.write("  " + json.dumps(r, ensure_ascii=False) + ",\n")
            fh.write("]\n\n")
        fh.write("export default {\n")
        for name, _ in tables:
            fh.write(f"  {name},\n")
        fh.write("}\n")
    write_swift(tables)
    print(OUT, SWIFT_OUT, {n: len(r) for n, r in tables})


def swift_string(value):
    # The TSVs carry a few escaped apostrophes from the decompiled resources.
    value = value.replace("\\'", "'")
    return json.dumps(value, ensure_ascii=False)


def write_swift(tables):
    with open(SWIFT_OUT, "w") as fh:
        fh.write("// GENERATED from docs/protocol/*.tsv by tools/gen-effects.py"
                 " — do not edit by hand.\n")
        fh.write("// swiftlint:disable all\n\n")
        fh.write("public enum EffectTables {\n")
        for name, rows in tables:
            fh.write(f"    public static let {name}: [LEDEffect] = [\n")
            for r in rows:
                group = f", group: {swift_string(r['group'])}" if r.get("group") else ""
                fh.write(f"        LEDEffect(id: {r['id']}, name: {swift_string(r['name'])}{group}),\n")
            fh.write("    ]\n")
        fh.write("}\n")


if __name__ == "__main__":
    main()
