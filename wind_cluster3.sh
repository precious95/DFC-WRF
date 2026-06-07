#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Fix WRF-downscaled CMIP6 daily wspd10max files.
#
# Corrected logic:
#   1. DO NOT use JULYR/JULDAY
#   2. Start retained WRF output at 1980-09-01
#   3. Make yearly files consecutive
#   4. Detect calendar per model:
#        - any yearly file with 366 days -> proleptic_gregorian
#        - all yearly files 365 days     -> 365_day
#   5. Merge yearly files per model
# ============================================================

BASE_IN="/home/eebiendele/wrf_downscaled/wrf-9km/historical-cmip6/wspd10max_d02_hist_bc"
BASE_OUT="/home/eebiendele/wrf_downscaled/wrf-9km/historical-cmip6/wspd_fixed"

START_YEAR=1980
END_YEAR=2013

VAR="wspd10max"
SCEN="hist"
DOMAIN="d02"

# First retained WRF output date after August spin-up
FIRST_START_DATE="1980-09-01"

DELETE_YEARLY_AFTER_MERGE=true
CLEAN_PARTIAL_YEARLY_AT_MODEL_START=true

mkdir -p "$BASE_OUT"

# ============================================================
# Model to realization mapping
# ============================================================
declare -A RUNS
RUNS["access-cm2"]="r5i1p1f1"
RUNS["cesm2"]="r11i1p1f1"
RUNS["cnrm-esm2-1"]="r1i1p1f2"
RUNS["ec-earth3"]="r1i1p1f1_2"
RUNS["ec-earth3-veg"]="r1i1p1f1"
RUNS["fgoals-g3"]="r1i1p1f1"
RUNS["miroc6"]="r1i1p1f1"
RUNS["mpi-esm1-2-hr"]="r3i1p1f1"
RUNS["mpi-esm1-2-lr"]="r7i1p1f1"
RUNS["noresm2-mm"]="r1i1p1f1"
RUNS["taiesm1"]="r1i1p1f1"

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

# ============================================================
# Check NetCDF file is valid and has time steps
# ============================================================
check_nc() {
  local f="$1"

  if [[ ! -s "$f" ]]; then
    echo "BAD FILE: missing or zero size: $f" >&2
    return 1
  fi

  if ! cdo -s sinfo "$f" >/dev/null 2>&1; then
    echo "BAD FILE: CDO cannot read: $f" >&2
    return 1
  fi

  local nt
  nt=$(cdo -s ntime "$f" 2>/dev/null | awk '{print $1}')

  if [[ -z "$nt" || "$nt" -le 0 ]]; then
    echo "BAD FILE: no time steps: $f" >&2
    return 1
  fi

  return 0
}

# ============================================================
# Get dimension length from ncdump header
# ============================================================
get_dim_len() {
  local file="$1"
  local dim="$2"

  ncdump -h "$file" | awk -v d="$dim" '
    $1 == d && $2 == "=" {
      val=$3
      gsub(/[^0-9]/, "", val)
      print val
      exit
    }
  '
}

# ============================================================
# Detect calendar type for each model from original yearly files
# ============================================================
detect_model_calendar() {
  local model="$1"
  local run="$2"
  local indir="$3"

  local has_366=0
  local seen=0

  for year in $(seq "$START_YEAR" "$END_YEAR"); do
    local f="${indir}/${VAR}.daily.${model}.${run}.${SCEN}.bias-correct.${DOMAIN}.${year}.nc"

    if [[ ! -f "$f" ]]; then
      continue
    fi

    local nday
    nday=$(get_dim_len "$f" "day")

    if [[ -z "$nday" ]]; then
      echo "WARNING: could not read day dimension from $f" >&2
      continue
    fi

    seen=1

    if [[ "$nday" -eq 366 ]]; then
      has_366=1
    fi
  done

  if [[ "$seen" -eq 0 ]]; then
    echo "unknown"
    return 1
  fi

  if [[ "$has_366" -eq 1 ]]; then
    echo "proleptic_gregorian"
  else
    echo "365_day"
  fi
}

# ============================================================
# Add N days using normal Gregorian date arithmetic
# ============================================================
add_days_gregorian() {
  local date_in="$1"
  local ndays="$2"

  python - <<PY
from datetime import datetime, timedelta
d = datetime.strptime("${date_in}", "%Y-%m-%d")
d2 = d + timedelta(days=int("${ndays}"))
print(d2.strftime("%Y-%m-%d"))
PY
}

# ============================================================
# Add N days using 365_day calendar arithmetic
# ============================================================
add_days_365() {
  local date_in="$1"
  local ndays="$2"

  python - <<PY
month_lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

date_in = "${date_in}"
ndays = int("${ndays}")

y, m, d = map(int, date_in.split("-"))

doy0 = sum(month_lengths[:m-1]) + (d - 1)
absolute = y * 365 + doy0
absolute2 = absolute + ndays

y2 = absolute2 // 365
rem = absolute2 % 365

m2 = 1
for ml in month_lengths:
    if rem < ml:
        d2 = rem + 1
        break
    rem -= ml
    m2 += 1

print(f"{y2:04d}-{m2:02d}-{d2:02d}")
PY
}

# ============================================================
# Advance date depending on detected model calendar
# ============================================================
advance_date() {
  local date_in="$1"
  local ndays="$2"
  local calendar="$3"

  if [[ "$calendar" == "365_day" ]]; then
    add_days_365 "$date_in" "$ndays"
  else
    add_days_gregorian "$date_in" "$ndays"
  fi
}

# ============================================================
# Print first and last dates safely
# ============================================================
print_first_last_dates() {
  local f="$1"

  local first_date
  local last_date

  first_date=$(cdo -s showdate "$f" | awk '{print $1; exit}')
  last_date=$(cdo -s showdate "$f" | awk '{for (i=1; i<=NF; i++) x=$i} END{print x}')

  echo "First date: $first_date"
  echo "Last date:  $last_date"
}

# ============================================================
# Main loop through models
# ============================================================
for MODEL in "${MODELS[@]}"; do

  RUN="${RUNS[$MODEL]}"

  INDIR="${BASE_IN}/${MODEL}"
  OUTDIR="${BASE_OUT}/${MODEL}"

  mkdir -p "$OUTDIR"

  merged_out="${OUTDIR}/${VAR}_${MODEL}_${SCEN}.nc"
  tmp_merged="${OUTDIR}/.${VAR}_${MODEL}_${SCEN}.tmp.nc"

  echo "============================================================"
  echo "MODEL:  $MODEL"
  echo "RUN:    $RUN"
  echo "INDIR:  $INDIR"
  echo "OUTDIR: $OUTDIR"
  echo "MERGED: $merged_out"
  echo "============================================================"

  if [[ ! -d "$INDIR" ]]; then
    echo "Missing model folder, skipping: $INDIR" >&2
    continue
  fi

  MODEL_CALENDAR=$(detect_model_calendar "$MODEL" "$RUN" "$INDIR")

  if [[ "$MODEL_CALENDAR" == "unknown" ]]; then
    echo "Could not detect calendar for $MODEL. Skipping." >&2
    continue
  fi

  echo "Detected calendar for $MODEL: $MODEL_CALENDAR"

  # Skip model if merged file already exists and is valid
  if check_nc "$merged_out" >/dev/null 2>&1; then
    echo "Merged file already exists and is valid. Skipping model: $MODEL"
    continue
  fi

  # Clean failed temporary files
  rm -f "${OUTDIR}"/.${VAR}_${MODEL}_*.tmp.nc
  rm -f "$tmp_merged"

  # Remove partial yearly files from previous failed run
  if [[ "$CLEAN_PARTIAL_YEARLY_AT_MODEL_START" == true ]]; then
    echo "Cleaning partial yearly corrected files for model: $MODEL"
    rm -f "${OUTDIR}/${VAR}_${MODEL}_"[0-9][0-9][0-9][0-9].nc
  fi

  # Running start date for this model
  current_start_date="$FIRST_START_DATE"

  # ============================================================
  # Process yearly files
  # ============================================================
  for year in $(seq "$START_YEAR" "$END_YEAR"); do

    in="${INDIR}/${VAR}.daily.${MODEL}.${RUN}.${SCEN}.bias-correct.${DOMAIN}.${year}.nc"
    out="${OUTDIR}/${VAR}_${MODEL}_${year}.nc"
    tmp_out="${OUTDIR}/.${VAR}_${MODEL}_${year}.tmp.nc"

    if [[ ! -f "$in" ]]; then
      echo "Missing input, skipping: $in" >&2
      continue
    fi

    if [[ ! -s "$in" ]]; then
      echo "Input file is empty, skipping: $in" >&2
      continue
    fi

    echo "------------------------------------------------------------"
    echo "Processing: $MODEL $year"
    echo "Input:  $in"
    echo "Output: $out"
    echo "Using consecutive start date: $current_start_date"
    echo "Using calendar: $MODEL_CALENDAR"

    tmpdir="$(mktemp -d -t ncfix_${MODEL}_${year}.XXXXXX)"
    a="${tmpdir}/_a.nc"
    b="${tmpdir}/_b.nc"
    c="${tmpdir}/_c.nc"
    hdr="${tmpdir}/header.txt"

    cleanup() {
      rm -rf "$tmpdir"
      rm -f "$tmp_out"
    }
    trap cleanup EXIT

    # Read header
    if ! ncdump -h "$in" > "$hdr"; then
      echo "ncdump failed for: $in" >&2
      trap - EXIT
      cleanup
      continue
    fi

    # Copy input to temporary working file
    cp -f "$in" "$a"

    ncdump -h "$a" > "$hdr"

    # ------------------------------------------------------------
    # Move existing time dimension/variable out of the way
    # ------------------------------------------------------------
    if grep -qE '^[[:space:]]*time[[:space:]]*=' "$hdr"; then
      echo "Renaming dimension: time -> time0"
      if ! ncrename -O -d time,time0 "$a"; then
        echo "Failed to rename time dimension in: $in" >&2
        trap - EXIT
        cleanup
        continue
      fi
    fi

    ncdump -h "$a" > "$hdr"

    if grep -qE '^[[:space:]]*(double|float|int|short|byte|char)[[:space:]]+time\(' "$hdr"; then
      echo "Renaming variable: time -> time0"
      if ! ncrename -O -v time,time0 "$a"; then
        echo "Failed to rename time variable in: $in" >&2
        trap - EXIT
        cleanup
        continue
      fi
    fi

    ncdump -h "$a" > "$hdr"

    # ------------------------------------------------------------
    # Rename day dimension to time
    # ------------------------------------------------------------
    if grep -qE '^[[:space:]]*day[[:space:]]*=' "$hdr"; then
      echo "Renaming dimension: day -> time"
      if ! ncrename -O -d day,time "$a" "$b"; then
        echo "Failed to rename day dimension in: $in" >&2
        trap - EXIT
        cleanup
        continue
      fi
    else
      echo "No day dimension found in: $in" >&2
      echo "Header dimensions are:" >&2
      grep -E '^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=' "$hdr" >&2 || true
      trap - EXIT
      cleanup
      continue
    fi

    ncdump -h "$b" > "$hdr"

    # Rename day variable to time if it exists
    if grep -qE '^[[:space:]]*(double|float|int|short|byte|char)[[:space:]]+day\(' "$hdr"; then
      echo "Renaming variable: day -> time"
      if ! ncrename -O -v day,time "$b"; then
        echo "Failed to rename day variable in: $in" >&2
        trap - EXIT
        cleanup
        continue
      fi
    fi

    # Make time unlimited/record dimension
    echo "Making time record dimension"
    if ! ncks -O --mk_rec_dmn time "$b" "$c"; then
      echo "Failed to make time record dimension: $in" >&2
      trap - EXIT
      cleanup
      continue
    fi

    # ------------------------------------------------------------
    # Assign consecutive daily time axis.
    #
    # No JULYR/JULDAY is used.
    # Calendar is detected per model.
    # ------------------------------------------------------------
    echo "Setting consecutive time axis"

    if ! cdo -O \
        -settaxis,"${current_start_date}",00:00:00,1day \
        -setcalendar,"${MODEL_CALENDAR}" \
        -settunits,days \
        "$c" "$tmp_out"; then

      echo "CDO time-axis setting failed for: $in" >&2
      trap - EXIT
      cleanup
      continue
    fi

    # Validate yearly output before saving
    if check_nc "$tmp_out"; then
      mv -f "$tmp_out" "$out"
      echo "Wrote valid yearly file: $out"
      echo -n "ntime: "
      nt_year=$(cdo -s ntime "$out" | awk '{print $1}')
      echo "$nt_year"
      print_first_last_dates "$out"
    else
      echo "Yearly output failed validation, not saving: $out" >&2
      trap - EXIT
      cleanup
      continue
    fi

    # Update next start date using the model's calendar
    current_start_date=$(advance_date "$current_start_date" "$nt_year" "$MODEL_CALENDAR")
    echo "Next file will start at: $current_start_date"

    trap - EXIT
    cleanup

  done

  # ============================================================
  # Merge yearly files for this model
  # ============================================================
  echo "------------------------------------------------------------"
  echo "Merging yearly files for model: $MODEL"
  echo "Merged output: $merged_out"

  rm -f "$tmp_merged"

  shopt -s nullglob
  yearly_files=("${OUTDIR}/${VAR}_${MODEL}_"[0-9][0-9][0-9][0-9].nc)
  shopt -u nullglob

  if (( ${#yearly_files[@]} == 0 )); then
    echo "No yearly files found for $MODEL, skipping merge" >&2
    continue
  fi

  mapfile -t yearly_files < <(printf "%s\n" "${yearly_files[@]}" | sort -V)

  echo "Number of yearly files to merge: ${#yearly_files[@]}"

  if ! cdo -O mergetime "${yearly_files[@]}" "$tmp_merged"; then
    echo "Merge failed for $MODEL. Keeping yearly files for checking." >&2
    rm -f "$tmp_merged"
    continue
  fi

  if check_nc "$tmp_merged"; then
    mv -f "$tmp_merged" "$merged_out"
    echo "Merged file written: $merged_out"
  else
    echo "Merged file failed validation for $MODEL. Keeping yearly files for checking." >&2
    rm -f "$tmp_merged"
    continue
  fi

  echo -n "Merged ntime: "
  cdo -s ntime "$merged_out"
  print_first_last_dates "$merged_out"

  # Delete yearly corrected files after valid merge
  if [[ "$DELETE_YEARLY_AFTER_MERGE" == true ]]; then
    echo "Deleting yearly corrected files for model: $MODEL"
    rm -f "${yearly_files[@]}"
    echo "Deleted yearly corrected files for model: $MODEL"
  else
    echo "Keeping yearly corrected files because DELETE_YEARLY_AFTER_MERGE=false"
  fi

  echo "Space after finishing $MODEL:"
  df -h "$BASE_OUT" || true
  du -sh "$OUTDIR" || true

done

echo "============================================================"
echo "DONE"
echo "Final output directory:"
echo "$BASE_OUT"
echo "============================================================"
