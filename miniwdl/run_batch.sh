#!/bin/bash
# Run the GATK-SV full batch pipeline (1kGP 3-sample) via miniwdl.
#
# Prerequisites (see README-della.md):
#   uv tool install miniwdl==1.14.2 --with miniwdl-slurm==0.4.0
#   miniwdl.cfg       — backend, call_cache, image_cache config
#   image_cache/      — pre-seeded SIF symlinks
#   inputs/GATKSVPipelineBatch.1kgp_3samples.miniwdl.json

MW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sbatch "$MW/miniwdl_run.sbatch" \
  "$MW/../wdl/GATKSVPipelineBatch.wdl" \
  "$MW/inputs/GATKSVPipelineBatch.1kgp_3samples.miniwdl.json"
