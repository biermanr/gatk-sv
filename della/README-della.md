# Running GATK-SV on the Della SLURM cluster (Apptainer, no Docker)

GATK-SV is officially GCP/Terra-only. This directory holds the recipe for running
it on Princeton's **Della** SLURM cluster with **Apptainer** (no Docker). Two
execution engines were brought up; **miniwdl-slurm is the recommended path**
because it dispatches each WDL task as its own right-sized `sbatch` job, so the
~287-shard gCNV scatter runs as parallel cluster jobs instead of OOM-ing a node.

The 6 patched WDLs this depends on are committed on this branch (`slurm-della`):
gCNV cohort-mode ploidy + `contig_ploidy_priors`, the WGD-100bp / gCNV-2kb
read-count split, and the CNMOPS empty-output guard.

## Track B — miniwdl + miniwdl-slurm (recommended)

Files here:
- `miniwdl.cfg` — `slurm_singularity` backend, Apptainer, pre-seeded image cache,
  file-based call cache, and the mandatory Della `--account`/`--time` sbatch args.
- `miniwdl_run.sbatch` — small long-lived orchestrator alloc; miniwdl runs inside
  it and submits per-task jobs. Defaults to a `GatherSampleEvidence` smoke test;
  pass `<top.wdl> <inputs.json>` to run something else (e.g. the full batch).
- `coerce_inputs_for_miniwdl.py` — turn a Cromwell inputs JSON into a
  miniwdl-accepted one (see "Gotcha: types" below).

### One-time setup
```bash
module load anaconda3
python3 -m venv <workspace>/venv && source <workspace>/venv/bin/activate
pip install miniwdl miniwdl-slurm
# Pre-seed the image cache with symlinks to existing SIFs so offline compute
# nodes never pull. miniwdl names cached images as:
#   ("docker://" + image).replace("/","_").replace(":","_") + ".sif"
```

### Run
```bash
cd <workspace>
sbatch miniwdl_run.sbatch                              # GatherSampleEvidence smoke test
sbatch miniwdl_run.sbatch <top.wdl> <inputs.miniwdl.json>   # e.g. full batch
```
`squeue -u $USER` will show many small per-task jobs — that's the dispatch working.

## Track A — local Cromwell 84 + docker→apptainer shim (fallback / reference)

A single big `sbatch` runs Cromwell's Local backend inside one node; a `docker`
shim on `PATH` rewrites `docker run` → `apptainer exec`. `concurrent-job-limit=8`
keeps the gCNV scatter from OOM-ing. Slower (single node) and kept mainly as a
correctness reference. See the `gatksv_run/` workspace (`run_cromwell.sbatch`,
`cromwell.local.conf`).

## Gotchas discovered during bring-up (all handled in the files here)

1. **CRAM index / htsjdk bug (critical).** The stock `.crai` indexes trigger
   `CRAMException: Attempt to create a bai entry for an unmapped slice ...` in every
   GATK tool (rc=3) for some CRAMs. Use **regenerated** indexes
   (`samtools index`) and point `bam_or_cram_indexes` at those.
2. **Types.** miniwdl rejects numbers encoded as JSON strings (`"0.5"`). Run the
   Cromwell inputs through `coerce_inputs_for_miniwdl.py` first. (miniwdl *does*
   accept the flattened nested sub-workflow keys — that part is fine.)
3. **Module metrics.** Set `run_*_metrics=false` (batch) / `run_module_metrics=false`
   (per module) — the metrics tasks `select_first()` on optional outputs/baselines
   we don't provide and abort the workflow otherwise.
4. **Optional caller dockers.** Manta/Wham/Scramble only run if
   `manta_docker`/`wham_docker`/`scramble_docker` are set — otherwise silently skipped.
5. **sbatch script:** don't use `set -u` (breaks `module`/venv activation with empty
   logs); task jobs need an explicit `--time` (Della rejects timeless jobs) — set via
   `miniwdl.cfg` `[slurm] extra_args`.
6. **`disks` ignored by miniwdl** — fine here: keep the run dir and `TMPDIR` on
   `/scratch/gpfs` (petabytes free); no per-task disk provisioning needed.
7. **Offline compute nodes** — no route to `us.gcr.io`. Pre-seed the SIF/image cache
   on a login node; disable Cromwell's remote docker-hash lookup.

## Cluster specifics
- `sbatch` requires `--account` (`akey`); partition `cpu` (15-day limit).
- Apptainer 1.4.5, Java 8/11/17 modules, Anaconda modules, no Docker.
