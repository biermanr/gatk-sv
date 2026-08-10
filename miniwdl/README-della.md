# GATK-SV on Della via miniwdl-slurm + Apptainer (Track B)

Per-task SLURM dispatch: miniwdl submits **each WDL task as its own `sbatch` job**
(right-sized from the task's `cpu`/`memory`), so the ~287-shard gCNV scatter runs
as ~287 parallel cluster jobs instead of oversubscribing one node (the Track A
single-node OOM cause).

## Layout
`miniwdl`/`miniwdl-slurm` aren't vendored here — installed once via
`uv tool install miniwdl==1.14.2 --with miniwdl-slurm==0.4.0` (places a stable
`~/.local/bin/miniwdl` shim; no venv/activation needed, and no re-install required
on subsequent runs, including from offline compute nodes).
```
gatk-sv/miniwdl/
├── miniwdl.cfg           backend=slurm_singularity, apptainer, image_cache, call_cache, --account=akey
├── image_cache/          14 symlinks -> existing SIFs (offline-safe; miniwdl skips pull when SIF present)
├── call_cache/           file-based call cache (resume on re-run)
├── inputs/
│   ├── GatherSampleEvidence.HG00514.miniwdl.json        first-module smoke test (validated)
│   ├── GATKSVPipelineBatch.1kgp_3samples.miniwdl.json   3-sample batch (validated; 19 string->typed fixes)
│   ├── GATKSVPipelineBatch.1kgp_10samples.miniwdl.json  10-sample batch, + 1kgp_10samples.ped
│   └── GATKSVPipelineBatch.1kgp_100samples.miniwdl.json 100-sample batch, + 1kgp_100samples.ped
│       (scaled up to give AdjudicateSV enough cross-sample agreement — see "Fixes applied" below)
├── miniwdl_run.sbatch    orchestrator (small long-lived alloc; dispatches task jobs)
└── runs/                 miniwdl run dirs (outputs under <run>/out/)
```

## Why the inputs differ from Track A (Cromwell)
Same values/paths, but miniwdl is stricter on types: 19 numeric inputs encoded as
JSON strings (e.g. `"0.5"`) were coerced to real numbers. Regenerate with the
snippet in this repo if inputs change. miniwdl DOES accept Cromwell's flattened
nested keys (`GATKSVPipelineBatch.MakeCohortVcf.*` etc.) — validated via
`values_from_json` (132 values bound).

## Bring-up order (recommended)
Run smallest-first and compare outputs to the Track A Cromwell reference. Submit
from this directory:

1. **GatherSampleEvidence (one sample)** — validates miniwdl+slurm+apptainer mechanics:
   ```
   sbatch miniwdl_run.sbatch
   ```
2. **3-sample batch** once the smoke test passes — `./run_batch.sh` (equivalent to
   `sbatch miniwdl_run.sbatch ../wdl/GATKSVPipelineBatch.wdl
   inputs/GATKSVPipelineBatch.1kgp_3samples.miniwdl.json`).
3. **Scale up** once the 3-sample batch passes and you need enough samples for
   `AdjudicateSV`'s cross-sample statistics to work (see "Fixes applied" below):
   ```
   sbatch miniwdl_run.sbatch ../wdl/GATKSVPipelineBatch.wdl \
          inputs/GATKSVPipelineBatch.1kgp_100samples.miniwdl.json
   ```

While a run is active, `squeue -u $USER` should show many small task jobs (one per
WDL task) — that's the per-task dispatch working.

## Known risks to watch (miniwdl vs Cromwell)
- **`disks` ignored** — mitigated: all scratch is on `/scratch/gpfs` (~5.4 PB free); `TMPDIR` set in the sbatch.
- **Host R libs (CNMOPS)** — mitigated by `--cleanenv --no-home` in `miniwdl.cfg` `run_options`.
  If CNMOPS still fails on R packages, add explicit `R_LIBS*=/dev/null` env inside the task.
- **`$HOME` inside the container** — `--no-home` stops apptainer from auto-mounting the real host
  home directory, but it still sets `$HOME` to that (now-absent) path inside the container, and the
  rootfs is read-only, so anything that tries to write under `$HOME` (matplotlib config, arviz's
  cache dir in `gcnvkernel`, etc.) crashes with `FileNotFoundError`/`Read-only file system`. Fixed
  with `--home /tmp` in `run_options`, which repoints `$HOME` at a location that exists and is
  writable in every image without reintroducing the real host homedir bind.
- **`glob` ordering / Cromwell-lenient semantics** — first place a full-batch miniwdl run might
  diverge from Cromwell; that's why we compare VCFs to the Track A reference.
- **Orchestrator on a compute node submitting sbatch** — allowed on Della; the orchestrator
  alloc is tiny (2 cpu / 8 GB) and just waits.
- **`copy_input_files = true` blows up disk usage at scale** — copying (rather than read-only
  bind-mounting) every task's inputs is needed because a handful of GATK-SV tasks `mv`/`rm` their
  own input files, which fails "Device or resource busy" on a bind mount. But applied blanket, it
  meant every per-sample task that merely *reads* the ~15GB CRAM (Whamg, Scramble, Manta,
  CollectSVEvidence, CollectCounts, CheckAligner, CollectWGDCounts...) got its own full copy —
  measured at ~211GB per sample instead of the expected ~15GB, i.e. ~19TB for a 90-sample batch's
  `GatherSampleEvidence` stage alone. Fixed by switching to `copy_input_files = false` with a
  `copy_input_files_for` allowlist of only the specific tasks that actually need write access to
  their inputs (`LocalizeReads`, `MergeEvidence`, `SDtoBAF`, `RestoreUnresolvedCnv`,
  `StitchFragmentedCnvs`, `PlotQcPerFamily`, `PostprocessGermlineCNVCalls`, `GetRegenotype`,
  `MakeRawCombinedBed` — found by grepping every `mv`/`rm` on a `File` input across the WDLs and
  cross-checking each against `miniwdl check`'s reachability output for `GATKSVPipelineBatch.wdl`).
  Modeled savings: ~4-4.5x per sample. Not yet re-validated end-to-end at 100-sample scale.

## Sibling directories (other engine/tracks on Della)

Two sibling dirs hold parallel attempts at running GATK-SV on Della with **Cromwell**
instead of miniwdl — kept as a comparison/fallback track, not part of this repo:

- **`../della/`** — single-sample pipeline (branch `cromwell_slurm_ss` in the
  `gatk-sv` checkout). **Complete**: `NA12878.gatk_sv.vcf.gz` (9,467 SVs, genotyped
  vs the 156-sample 1kGP panel), plus HG00514 and NA19240 runs. Engine: Cromwell 84,
  **hybrid backend** (`cromwell.hybrid.conf`) — most tasks on one Local-backend node
  (16 cpu / 80 GB orchestrator job), with only the memory-heavy cnMOPS `CNSampleNormal`
  task offloaded to right-sized Slurm-backend jobs. `call-caching.enabled = true` is
  set, but per the user this is not actually resuming failed runs — worth comparing
  against how `call_cache/` works here in miniwdl.
- **`../../gatksv_ss/`** — the 1kGP 3-sample **batch** pipeline (`GATKSVPipelineBatch`,
  the counterpart to this dir's full-batch input set) on Cromwell, single-node
  **Local backend only** (`cromwell.local.conf`, `concurrent-job-limit = 8` to avoid
  OOM on the ~287-shard gCNV scatter). Same `call-caching.enabled = true` setting and
  same reported problem: runs get most of the way through and a failure forces a
  restart from scratch instead of resuming from cache.

**Update (2026-07-16/17):** root-caused, but turned out to be three independent bugs
in the Cromwell tracks, not one — the third is still being validated. See
`../della/README-della.md` gotcha #5 for the full writeup. Short version:

1. `docker.hash-lookup.enabled = false` (set to skip remote digest lookups on
   offline compute nodes) doesn't just skip the lookup — it makes Cromwell unable
   to compute a docker hash for *any* task with a floating tag, so literally every
   task (2,817/2,817 in one run's log) logged `is not eligible for call caching`
   and reran from scratch every time, despite `call-caching.enabled = true`.
   Fixed by switching to `docker.hash-lookup.method = "local"`.
2. `java -jar cromwell.jar run` starts a fresh JVM (and fresh in-memory database)
   per `sbatch` submission — with no persistent `database` block, call-cache
   metadata never survives across separate job submissions regardless of (1).
   Fixed by adding a file-based HSQLDB.
3. The `scripts/docker` shim's `images` handling was still wrong in two ways:
   Cromwell's hash-lookup calls `docker images --digests --format ...` with *no
   image-name filter at all* (lists everything, matches client-side), and
   separately uses the Docker-Hub-canonicalized image name (`docker.io/library/
   ubuntu:18.04`) rather than the short form `pull`/`run` see. Both only became
   visible by adding an invocation tracer to the shim itself. Redesigned the shim
   around a small manifest file populated by `run`/`pull` — **not yet confirmed
   working**; a live trace showed a possible race between the manifest write and
   the very next read. A validation job was left running overnight to see if it
   completes despite this. Cromwell work is paused pending that result.

## Fixes applied (miniwdl batch track)

Status as of 2026-07-20. `GATKSVPipelineBatch.wdl` now runs substantially further under
miniwdl than any engine had previously exercised it in this project — through
`GatherSampleEvidence`, `ClusterBatch`, and `GenerateBatchMetrics` cleanly, into
`FilterBatch`/`FilterBatchSites`. Every bug hit so far has been narrow and fixable at the
WDL-source level, not a fundamental miniwdl limitation:

1. **The `<file> + ".suffix"` index-derivation idiom** — assumes Cromwell-style co-located
   task outputs; under miniwdl's per-output-subdirectory layout the derived path doesn't
   exist. Hit and fixed in four places, each by threading the real, already-computed index
   output through as a proper input instead of deriving it:
   - `TinyResolve.wdl`'s `discfile_idx` (from `GatherSampleEvidenceBatch`'s `pesr_disc_index`),
     threaded through `GatherBatchEvidence.wdl`.
   - `GenerateBatchMetrics.wdl`'s `vcfs_index_`/`pe_file_index`/`sr_file_index`/`baf_file_index`/
     `rd_file_index` (from `ClusterBatch`'s/`GatherBatchEvidence`'s already-real index outputs),
     threaded through `GATKSVPipelinePhase1.wdl`.
   - `GenotypeBatch.wdl`'s `vcf_index`/`rd_file_index`/`pe_file_index`/`sr_file_index`, threaded
     through `GATKSVPipelineBatch.wdl` from `MergePesrDepthVcfs`'s/`GATKSVPipelinePhase1`'s real
     index outputs.
   - A proactive grep for the same idiom (`grep -n '+ *"\.\(tbi\|crai\|idx\|bai\)"' *.wdl`) turned
     up ~50 more hits across the WDLs, but most touch static reference-resource files (real,
     already-colocated `.tbi` siblings on disk, e.g. `segdups`/`rmsk`/`bin_exclude`) rather than
     task outputs, so they're harmless. Only fix the ones that trace back to another task's
     output when they're actually hit.
   - `CollectCoverage.wdl` also had an unquoted `default=` on an `Int` placeholder
     (`--max-interval-size ~{default=2000 ...}` → needs `default="2000"`), a related but distinct
     miniwdl-strictness issue (same class as the earlier `File`/`File?` mismatch on
     `master_vcf_qc`).
2. **`determine_svcount_outliers.R` crashes on an all-zero `svcounts.txt`** — a small/sparse
   batch can legitimately produce zero SVs for one algorithm (e.g. Scramble), which crashes
   `colnames<-(NULL, ...)` in the outlier-plotting script. Confirmed this is diagnostic-only
   (nothing downstream reads `PlotSVCountsPerSample`'s outputs; the actual sample-filtering
   logic in `FilterBatchSamples`/`IdentifyOutlierSamples` uses a separate, already-safe script).
   Patched to write an empty outliers file + placeholder plot instead of crashing, and
   bind-mounted over the in-image copy via `miniwdl.cfg`'s `run_options` (see `miniwdl/` in this
   repo — the running container's `/opt/sv-pipeline/scripts/...` is a frozen copy from whatever
   commit the image was built at, so editing `src/sv-pipeline/scripts/...` alone does nothing
   without this).
3. **`$HOME`/`copy_input_files` runtime issues** — see "Known risks" above.

### Current blocker: `AdjudicateSV` needs more cross-sample statistical power than a small batch has

`FilterBatchSites`' `AdjudicateSV` step trains a random-forest PASS/FAIL classifier using
labels it derives itself from cross-algorithm agreement in the evidence metrics. At 10
samples it raised `Exception: No Pass variants included in training set` (55,850 candidate
sites present — plenty of data volume, just no site got a confident "Pass" label). This
matches GATK-SV's documented ~100-500 sample batch recommendation, not a miniwdl bug. Scaled
the batch to 100 samples (90 more downloaded from the 1000 Genomes 30x high-coverage set,
`/scratch/gpfs/AKEY/1kg-phase3/CRAMs/`; note their `.crai` indexes needed reindexing with a
modern `samtools` — the EBI-hosted ones hit an unrelated htsjdk incompatibility,
`CRAMException: Attempt to create a bai entry for an unmapped slice...`) — but hit the
`copy_input_files` disk-usage blowup (~24TB) partway through `GatherSampleEvidence` before
reaching `AdjudicateSV` again. Root-caused and fixed (see "Known risks"); all run directories
were deleted to reclaim disk before re-validating.

**Next:** resubmit the 100-sample batch with the `copy_input_files_for` fix in place. Confirm
the modeled ~4-4.5x disk reduction holds, and whether 100 samples gives `AdjudicateSV` enough
cross-sample agreement to find Pass-labeled training variants. If it still fails, either scale
further or investigate supplying `adjudicate_cutoffs`/`adjudicate_scores`/`adjudicate_rf_files`
from an existing reference-panel run to skip the step entirely (a partial match exists at
`.../gatk-sv-ref-panel-1kg-v1-1/.../FilterBatchSites/.../call-AdjudicateSV/all_samples.cutoffs`,
but is missing the `.scores`/`.RF_intermediate_files.tar.gz` siblings the skip path requires).
