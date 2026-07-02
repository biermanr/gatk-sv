#!/bin/bash
#SBATCH --job-name=gatksv_miniwdl
#SBATCH --account=akey
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=48:00:00
#SBATCH --output=logs/miniwdl_%j.out
#SBATCH --error=logs/miniwdl_%j.err
# ---------------------------------------------------------------------------
# miniwdl orchestrator for GATK-SV on Della.
#
# Small long-lived allocation: miniwdl itself is lightweight and just waits,
# while the miniwdl-slurm plugin submits EACH WDL task as its own sbatch job
# (right-sized from the task's cpu/memory). The ~287-shard gCNV scatter thus
# becomes ~287 independent cluster jobs -> no single-node OOM.
#
# Submit from the miniwdl workspace:
#   sbatch miniwdl_run.sbatch                              # default: GatherSampleEvidence smoke test
#   sbatch miniwdl_run.sbatch <top.wdl> <inputs.json>     # e.g. the full batch
# ---------------------------------------------------------------------------
echo "[start] $(date) host=$(hostname) pwd=$(pwd)"

MW=/scratch/gpfs/AKEY/rbierman/gatksv_miniwdl
FORK=/scratch/gpfs/AKEY/rbierman/gatk-sv

# Default target: single-module bring-up (recommended first run). Override via args.
WDL="${1:-$FORK/wdl/GatherSampleEvidence.wdl}"
INPUTS="${2:-$MW/inputs/GatherSampleEvidence.HG00514.miniwdl.json}"

# The venv's python is an absolute anaconda interpreter, so no `module load`
# is required; activate just puts miniwdl/venv on PATH.
source "$MW/venv/bin/activate" || { echo "ERROR: could not activate venv"; exit 1; }

echo "[env] python=$(command -v python) miniwdl=$(command -v miniwdl)"
echo "[env] apptainer=$(command -v apptainer) sbatch=$(command -v sbatch)"
command -v apptainer >/dev/null || { echo "ERROR: apptainer not found on node"; exit 1; }
command -v sbatch    >/dev/null || { echo "ERROR: sbatch not available inside allocation"; exit 1; }

export MINIWDL_CFG="$MW/miniwdl.cfg"
export TMPDIR="$MW/tmp"
mkdir -p "$TMPDIR" "$MW/logs" "$MW/runs"

STAMP=$(date +%Y%m%d_%H%M%S)
RUNDIR="$MW/runs/$(basename "${WDL%.wdl}").$STAMP"
echo "[miniwdl] WDL   = $WDL"
echo "[miniwdl] INPUT = $INPUTS"
echo "[miniwdl] rundir= $RUNDIR"

set -o pipefail
miniwdl run \
  --cfg "$MINIWDL_CFG" \
  --dir "$RUNDIR" \
  --input "$INPUTS" \
  --verbose \
  "$WDL"
rc=$?

echo "[miniwdl] exit code: $rc"
echo "[miniwdl] outputs (if success): $RUNDIR/out/  (outputs.json + _LAST symlink)"
exit $rc
