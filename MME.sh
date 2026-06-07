#!/usr/bin/env bash
set -u

# ============================================================
# Convert all wspd10max historical model files to common 365_day
# calendar, then compute ensemble mean.
#
# This version avoids pipefail/head/tail crashes.
# ============================================================

INDIR="$(pwd)"
OUTDIR="${INDIR}/common_365day"
MME_OUT="${OUTDIR}/wspd10max_MME_hist.nc"

START_DATE="1980-09-01"

mkdir -p "$OUTDIR"

MODELS=(
  "access-cm2"
  "cesm2"
  "cnrm-esm2-1"
  "ec-earth3"
  "ec-earth3-veg"
  "fgoals-g3"
  "miroc6"
  "mpi-esm1-2-hr"
  "mpi-esm1-2-lr"
  "noresm2-mm"
  "taiesm1"
)

echo "============================================================"
echo "Input directory:  $INDIR"
echo "Output directory: $OUTDIR"
echo "Start date:       $START_DATE"
echo "============================================================"

# Fix possible taiesm1 filename without .nc
if [[ -f "${INDIR}/wspd10max_taiesm1" && ! -f "${INDIR}/wspd10max_taiesm1_hist.nc" ]]; then
  echo "Renaming wspd10max_taiesm1 to wspd10max_taiesm1_hist.nc"
  mv "${INDIR}/wspd10max_taiesm1" "${INDIR}/wspd10max_taiesm1_hist.nc"
fi

# Safe function to print first/last date without head/tail pipefail issue
print_first_last_dates() {
  local f="$1"
  local dates_file
  dates_file="$(mktemp)"

  cdo -s showdate "$f" | tr ' ' '\n' | grep -v '^$' > "$dates_file"

  first_date=$(awk 'NR==1 {print; exit}' "$dates_file")
  last_date=$(awk 'NF {x=$0} END {print x}' "$dates_file")

  echo "First date:  $first_date"
  echo "Last date:   $last_date"

  rm -f "$dates_file"
}

# ============================================================
# Convert each model to common 365_day calendar
# ============================================================
for model in "${MODELS[@]}"; do

  in="${INDIR}/wspd10max_${model}_hist.nc"
  out="${OUTDIR}/wspd10max_${model}_hist.nc"
  tmp="${OUTDIR}/.${model}_tmp_noleap.nc"

  echo "============================================================"
  echo "Model: $model"
  echo "Input: $in"
  echo "Output: $out"

  if [[ ! -f "$in" ]]; then
    echo "ERROR: missing input file: $in"
    echo "Skipping $model"
    continue
  fi

  nt=$(cdo -s ntime "$in" | awk '{print $1}')

  if [[ -z "$nt" ]]; then
    echo "ERROR: could not read ntime for $in"
    echo "Skipping $model"
    continue
  fi

  echo "Original ntime: $nt"

  rm -f "$out" "$tmp"

  if [[ "$nt" -eq 12418 ]]; then
    echo "Gregorian/leap-day file detected. Removing Feb 29 first."

    if ! cdo -O delete,month=2,day=29 "$in" "$tmp"; then
      echo "ERROR: failed to delete Feb 29 for $model"
      rm -f "$tmp"
      continue
    fi

    nt_tmp=$(cdo -s ntime "$tmp" | awk '{print $1}')
    echo "After deleting Feb 29, ntime: $nt_tmp"

    if [[ "$nt_tmp" -ne 12410 ]]; then
      echo "ERROR: expected 12410 after deleting Feb 29, got $nt_tmp"
      rm -f "$tmp"
      continue
    fi

    if ! cdo -O \
      -settaxis,"${START_DATE}",00:00:00,1day \
      -setcalendar,365_day \
      "$tmp" "$out"; then
      echo "ERROR: failed to reset calendar for $model"
      rm -f "$tmp"
      continue
    fi

    rm -f "$tmp"

  elif [[ "$nt" -eq 12410 ]]; then
    echo "No-leap length detected. Resetting time axis/calendar only."

    if ! cdo -O \
      -settaxis,"${START_DATE}",00:00:00,1day \
      -setcalendar,365_day \
      "$in" "$out"; then
      echo "ERROR: failed to reset calendar for $model"
      continue
    fi

  else
    echo "ERROR: unexpected ntime=$nt for $in"
    echo "Expected either 12418 or 12410."
    echo "Skipping $model"
    continue
  fi

  if [[ ! -s "$out" ]]; then
    echo "ERROR: output missing or empty for $model"
    continue
  fi

  final_nt=$(cdo -s ntime "$out" | awk '{print $1}')
  echo "Wrote: $out"
  echo "Final ntime: $final_nt"
  print_first_last_dates "$out"

done

# ============================================================
# Check that all 11 common files exist
# ============================================================
echo "============================================================"
echo "Checking all expected common_365day files"
echo "============================================================"

missing=0

for model in "${MODELS[@]}"; do
  f="${OUTDIR}/wspd10max_${model}_hist.nc"

  if [[ ! -f "$f" ]]; then
    echo "MISSING: $f"
    missing=1
    continue
  fi

  nt=$(cdo -s ntime "$f" | awk '{print $1}')
  echo "$(basename "$f")  ntime=$nt"

  if [[ "$nt" -ne 12410 ]]; then
    echo "BAD NTIME: $(basename "$f") has $nt, expected 12410"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "============================================================"
  echo "Some files are missing or have wrong ntime. Ensemble mean not created."
  echo "Check the messages above."
  echo "============================================================"
  exit 1
fi

# ============================================================
# Compute ensemble mean using explicit file list
# ============================================================
echo "============================================================"
echo "Computing ensemble mean"
echo "Output: $MME_OUT"
echo "============================================================"

rm -f "$MME_OUT"

if ! cdo -O ensmean \
  "${OUTDIR}/wspd10max_access-cm2_hist.nc" \
  "${OUTDIR}/wspd10max_cesm2_hist.nc" \
  "${OUTDIR}/wspd10max_cnrm-esm2-1_hist.nc" \
  "${OUTDIR}/wspd10max_ec-earth3_hist.nc" \
  "${OUTDIR}/wspd10max_ec-earth3-veg_hist.nc" \
  "${OUTDIR}/wspd10max_fgoals-g3_hist.nc" \
  "${OUTDIR}/wspd10max_miroc6_hist.nc" \
  "${OUTDIR}/wspd10max_mpi-esm1-2-hr_hist.nc" \
  "${OUTDIR}/wspd10max_mpi-esm1-2-lr_hist.nc" \
  "${OUTDIR}/wspd10max_noresm2-mm_hist.nc" \
  "${OUTDIR}/wspd10max_taiesm1_hist.nc" \
  "$MME_OUT"; then

  echo "ERROR: cdo ensmean failed"
  exit 1
fi

echo "============================================================"
echo "MME complete"
echo "============================================================"

echo -n "MME ntime: "
cdo -s ntime "$MME_OUT"

print_first_last_dates "$MME_OUT"

echo "MME file:"
echo "$MME_OUT"
