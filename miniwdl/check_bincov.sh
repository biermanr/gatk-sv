#!/bin/bash
# Sanity-check the EvidenceQC bincov matrix for a run.
#
# This matrix is not just QC output: it becomes the RD evidence for
# GenerateBatchMetrics and the input to MedianCov and cn.MOPS. If it is built
# from the wrong counts (e.g. the WGD scoring-mask intervals) every task still
# succeeds, but depth evidence silently vanishes and the run dies much later in
# FilterBatchSites.AdjudicateSV with "No Pass variants included in training set".
#
# Usage: sh check_bincov.sh <run_dir> [expected_n_samples]

set -uo pipefail
RUN="${1:?usage: check_bincov.sh <run_dir> [expected_n_samples]}"
EXPECT_N="${2:-}"

M=$(find "$RUN" -maxdepth 6 -path "*call-EvidenceQC/out/bincov_matrix/*.RD.txt.gz" 2>/dev/null | head -1)
# Fall back to the ZPaste work file if the workflow has not linked outputs yet.
if [ -z "$M" ]; then
  M=$(find "$RUN" -maxdepth 8 -path "*call-EvidenceQC/call-MakeBincovMatrix/call-ZPaste/work/*.RD.txt.gz" \
        ! -path "*_miniwdl_inputs*" 2>/dev/null | head -1)
fi
if [ -z "$M" ]; then
  echo "PENDING: EvidenceQC bincov matrix not produced yet under $RUN"
  exit 2
fi

hdr=$(zcat "$M" | head -1)
ncol=$(printf '%s' "$hdr" | awk -F'\t' '{print NF}')
nrow=$(zcat "$M" | tail -n +2 | wc -l)
binsize=$(zcat "$M" | sed -n '2p' | awk '{print $3-$2}')
nsamp=$((ncol - 3))

echo "matrix:   $M"
echo "bins:     $nrow"
echo "bin size: ${binsize} bp"
echo "samples:  $nsamp"

rc=0
# Genome-wide coverage at 2 kb bins is ~1.4M rows. The WGD scoring mask is ~1.8k.
if [ "$nrow" -lt 100000 ]; then
  echo "FAIL: only $nrow bins -- this is not a genome-wide matrix."
  echo "      Check that EvidenceQC.counts is wired to counts_files_, not CollectWGDCounts.counts."
  rc=1
fi
if [ "$binsize" != 2000 ]; then
  echo "WARN: bin size ${binsize} bp, expected 2000 (from preprocessed_intervals)."
  echo "      100 bp means the WGD scoring-mask counts were used by mistake."
  [ "$binsize" = 100 ] && rc=1
fi
if [ -n "$EXPECT_N" ] && [ "$nsamp" != "$EXPECT_N" ]; then
  echo "FAIL: $nsamp sample columns, expected $EXPECT_N."
  rc=1
fi

[ "$rc" = 0 ] && echo "OK"
exit $rc
