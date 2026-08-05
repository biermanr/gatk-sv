#!/bin/bash
# Run the GATK-SV full batch pipeline (1kGP 3-sample) via miniwdl.
#
# Prerequisites (see README-della.md):
#   uv tool install miniwdl==1.14.2 --with miniwdl-slurm==0.4.0
#   miniwdl.cfg       — backend, call_cache, image_cache config
#   image_cache/      — pre-seeded SIF symlinks
#   inputs/GATKSVPipelineBatch.1kgp_3samples.miniwdl.json

#   sh run_batch.sh                 # 3-sample batch (default)
#   sh run_batch.sh 1kgp_100samples # any inputs/GATKSVPipelineBatch.<name>.miniwdl.json

MW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATCH="${1:-1kgp_3samples}"
INPUTS="$MW/inputs/GATKSVPipelineBatch.$BATCH.miniwdl.json"

[ -f "$INPUTS" ] || { echo "ERROR: no such inputs file: $INPUTS"; exit 1; }

sbatch "$MW/miniwdl_run.sbatch" \
  "$MW/../wdl/GATKSVPipelineBatch.wdl" \
  "$INPUTS"
