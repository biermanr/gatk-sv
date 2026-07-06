#!/usr/bin/env python3
"""Adapt a Cromwell-style GATK-SV inputs JSON for miniwdl.

miniwdl accepts GATK-SV's flattened nested keys (e.g.
GATKSVPipelineBatch.MakeCohortVcf.track_bed_files) but is stricter than Cromwell
about types: numeric inputs encoded as JSON strings ("0.5", "30") must be real
numbers. This script coerces those to the WDL-declared type so miniwdl's input
binder accepts them.

Usage:
    python coerce_inputs_for_miniwdl.py <top_workflow.wdl> <cromwell_inputs.json> <out.json>

Requires: miniwdl (pip install miniwdl) — imported as WDL.
"""
import json
import os
import sys

import WDL
from WDL import values_from_json


def main(wdl_path, src, dst):
    doc = WDL.load(wdl_path, path=[os.path.dirname(os.path.abspath(wdl_path))])
    wf = doc.workflow
    pfx = wf.name + "."
    # available_inputs is a WDL.Env.Bindings; binding names lack the top prefix.
    types = {b.name: b.value.type for b in wf.available_inputs}

    def coerce(key, val):
        t = types.get(key[len(pfx):] if key.startswith(pfx) else key)
        if t is None or not isinstance(val, str):
            return val, False
        tn = str(t).replace("?", "")
        try:
            if tn == "Float":
                return float(val), True
            if tn == "Int":
                return int(val), True
            if tn == "Boolean" and val.lower() in ("true", "false"):
                return val.lower() == "true", True
        except ValueError:
            pass
        return val, False

    inp = json.load(open(src))
    out, fixed = {}, []
    for k, v in inp.items():
        nv, changed = coerce(k, v)
        out[k] = nv
        if changed:
            fixed.append(k)

    json.dump(out, open(dst, "w"), indent=2, sort_keys=True)

    # Validate that miniwdl now accepts the result (raises on failure).
    values_from_json(out, wf.available_inputs, wf.required_inputs, namespace=wf.name)
    print(f"coerced {len(fixed)} string->typed values; miniwdl accepted the inputs")
    for k in fixed:
        print("  ", k, "->", out[k])


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:4])
