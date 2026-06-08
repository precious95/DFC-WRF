#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Fix WRF-downscaled CMIP6 daily prec SSP370 files.
#
# Target final period:
#   2040-01-01 to 2059-12-31
#
# Because WRF retained files are water-year style:
#   file 2039 = 2039-09-01 to 2040-08-31
#   file 2059 = 2059-09-01 to 2060-08-31
#
# So we process 2039-2059, merge, then select exact dates.
# ============================================================

BASE_IN="/home/eebiendele/wrf_downscaled/wrf-9km/ssp370/prec_d02_ssp370_bc"
BASE_OUT="/home/eebiendele/wrf_downscaled/wrf-9km/ssp370/prec_fixed_ssp370_2040_2059"

START_YEAR=2039
END_YEAR=2059

VAR="prec"
SCEN="ssp370"
DOMAIN="d02"

# First retained WRF output date for the first selected water year
FIRST_START_DATE="2039-09-01"

# Final exact calendar-period selection
FINAL_START_DATE="2040-01-01"
FINAL_END_DATE="2059-12-31"

DELETE_YEARLY_AFTER_MERGE=true
DELETE_FULL_MERGE_AFTER_SELDATE=true
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

  merged_full="${OUTDIR}/${VAR}_${MODEL}_${SCEN}_wy${START_YEAR}_${END_YEAR}_full.nc"
  final_out="${OUTDIR}/${VAR}_${MODEL}_${SCEN}_2040_2059.nc"

  tmp_merged="${OUTDIR}/.${VAR}_${MODEL}_${SCEN}.merged.tmp.nc"
  tmp_final="${OUTDIR}/.${VAR}_${MODEL}_${SCEN}.2040_2059.tmp.nc"

  echo "============================================================"
  echo "MODEL:      $MODEL"
  echo "RUN:        $RUN"
  echo "INDIR:      $INDIR"
  echo "OUTDIR:     $OUTDIR"
  echo "FULL MERGE: $merged_full"
  echo "FINAL OUT:  $final_out"
  echo "============================================================"

  if [[ ! -d "$INDIR" ]]; then
    echo "ERROR: missing model folder: $INDIR" >&2
    exit 1
  fi

  MODEL_CALENDAR=$(detect_model_calendar "$MODEL" "$RUN" "$INDIR")

  if [[ "$MODEL_CALENDAR" == "unknown" ]]; then
    echo "ERROR: could not detect calendar for $MODEL" >&2
    exit 1
  fi

  echo "Detected calendar for $MODEL: $MODEL_CALENDAR"

  if check_nc "$final_out" >/dev/null 2>&1; then
    echo "Final file already exists and is valid. Skipping model: $MODEL"
    continue
  fi

  rm -f "${OUTDIR}"/.${VAR}_${MODEL}_*.tmp.nc
  rm -f "$tmp_merged" "$tmp_final"

  if [[ "$CLEAN_PARTIAL_YEARLY_AT_MODEL_START" == true ]]; then
    echo "Cleaning partial yearly corrected files for model: $MODEL"
    rm -f "${OUTDIR}/${VAR}_${MODEL}_"[0-9][0-9][0-9][0-9].nc
  fi

  current_start_date="$FIRST_START_DATE"

  # ============================================================
  # Process yearly WRF files
  # ============================================================
  for year in $(seq "$START_YEAR" "$END_YEAR"); do

    in="${INDIR}/${VAR}.daily.${MODEL}.${RUN}.${SCEN}.bias-correct.${DOMAIN}.${year}.nc"
    out="${OUTDIR}/${VAR}_${MODEL}_${year}.nc"
    tmp_out="${OUTDIR}/.${VAR}_${MODEL}_${year}.tmp.nc"

    if [[ ! -f "$in" ]]; then
      echo "ERROR: missing input file: $in" >&2
      exit 1
    fi

    if [[ ! -s "$in" ]]; then
      echo "ERROR: input file is empty: $in" >&2
      exit 1
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

    if ! ncdump -h "$in" > "$hdr"; then
      echo "ERROR: ncdump failed for: $in" >&2
      trap - EXIT
      cleanup
      exit 1
    fi

    cp -f "$in" "$a"

    ncdump -h "$a" > "$hdr"

    # Move existing time dimension/variable out of the way
    if grep -qE '^[[:space:]]*time[[:space:]]*=' "$hdr"; then
      echo "Renaming dimension: time -> time0"
      if ! ncrename -O -d time,time0 "$a"; then
        echo "ERROR: failed to rename time dimension in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    fi

    ncdump -h "$a" > "$hdr"

    if grep -qE '^[[:space:]]*(double|float|int|short|byte|char)[[:space:]]+time\(' "$hdr"; then
      echo "Renaming variable: time -> time0"
      if ! ncrename -O -v time,time0 "$a"; then
        echo "ERROR: failed to rename time variable in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    fi

    ncdump -h "$a" > "$hdr"

    # Rename day dimension to time
    if grep -qE '^[[:space:]]*day[[:space:]]*=' "$hdr"; then
      echo "Renaming dimension: day -> time"
      if ! ncrename -O -d day,time "$a" "$b"; then
        echo "ERROR: failed to rename day dimension in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    else
      echo "ERROR: no day dimension found in: $in" >&2
      grep -E '^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=' "$hdr" >&2 || true
      trap - EXIT
      cleanup
      exit 1
    fi

    ncdump -h "$b" > "$hdr"

    # Rename day variable to time if it exists
    if grep -qE '^[[:space:]]*(double|float|int|short|byte|char)[[:space:]]+day\(' "$hdr"; then
      echo "Renaming variable: day -> time"
      if ! ncrename -O -v day,time "$b"; then
        echo "ERROR: failed to rename day variable in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    fi

    # Make time unlimited/record dimension
    echo "Making time record dimension"
    if ! ncks -O --mk_rec_dmn time "$b" "$c"; then
      echo "ERROR: failed to make time record dimension: $in" >&2
      trap - EXIT
      cleanup
      exit 1
    fi

    # Assign consecutive daily time axis
    echo "Setting consecutive time axis"

    if ! cdo -O \
        -settaxis,"${current_start_date}",00:00:00,1day \
        -setcalendar,"${MODEL_CALENDAR}" \
        -settunits,days \
        "$c" "$tmp_out"; then

      echo "ERROR: CDO time-axis setting failed for: $in" >&2
      trap - EXIT
      cleanup
      exit 1
    fi

    # Validate yearly output before saving
    if check_nc "$tmp_out"; then
      mv -f "$tmp_out" "$out"
      echo "Wrote valid yearly file: $out"

      nt_year=$(cdo -s ntime "$out" | awk '{print $1}')
      echo "ntime: $nt_year"
      print_first_last_dates "$out"
    else
      echo "ERROR: yearly output failed validation: $out" >&2
      trap - EXIT
      cleanup
      exit 1
    fi

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
  echo "Full merged output: $merged_full"

  rm -f "$tmp_merged" "$merged_full"

  shopt -s nullglob
  yearly_files=("${OUTDIR}/${VAR}_${MODEL}_"[0-9][0-9][0-9][0-9].nc)
  shopt -u nullglob

  if (( ${#yearly_files[@]} == 0 )); then
    echo "ERROR: no yearly files found for $MODEL" >&2
    exit 1
  fi

  mapfile -t yearly_files < <(printf "%s\n" "${yearly_files[@]}" | sort -V)

  echo "Number of yearly files to merge: ${#yearly_files[@]}"

  if ! cdo -O mergetime "${yearly_files[@]}" "$tmp_merged"; then
    echo "ERROR: merge failed for $MODEL" >&2
    rm -f "$tmp_merged"
    exit 1
  fi

  if check_nc "$tmp_merged"; then
    mv -f "$tmp_merged" "$merged_full"
    echo "Full merged file written: $merged_full"
  else
    echo "ERROR: full merged file failed validation for $MODEL" >&2
    rm -f "$tmp_merged"
    exit 1
  fi

  echo "Full merged file check:"
  echo -n "ntime: "
  cdo -s ntime "$merged_full"
  print_first_last_dates "$merged_full"

  # ============================================================
  # Select exact final calendar period: 2040-01-01 to 2059-12-31
  # ============================================================
  echo "------------------------------------------------------------"
  echo "Selecting final exact period:"
  echo "$FINAL_START_DATE to $FINAL_END_DATE"
  echo "Final output: $final_out"

  rm -f "$tmp_final" "$final_out"

  if ! cdo -O seldate,"${FINAL_START_DATE}","${FINAL_END_DATE}" \
      "$merged_full" "$tmp_final"; then
    echo "ERROR: seldate failed for $MODEL" >&2
    rm -f "$tmp_final"
    exit 1
  fi

  if check_nc "$tmp_final"; then
    mv -f "$tmp_final" "$final_out"
    echo "Final selected file written: $final_out"
  else
    echo "ERROR: final selected file failed validation for $MODEL" >&2
    rm -f "$tmp_final"
    exit 1
  fi

  echo "Final selected file check:"
  echo -n "ntime: "
  cdo -s ntime "$final_out"
  print_first_last_dates "$final_out"

  # Delete full water-year merge after exact selection, if requested
  if [[ "$DELETE_FULL_MERGE_AFTER_SELDATE" == true ]]; then
    echo "Deleting full merged water-year file:"
    echo "$merged_full"
    rm -f "$merged_full"
  fi

  # Delete yearly corrected files after valid final output
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
