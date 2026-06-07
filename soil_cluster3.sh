#!/usr/bin/env bash
set -u

# ============================================================
# Fix WRF-downscaled CMIP6 daily soil_m files.
#
# Corrected logic:
#   1. DO NOT use JULYR/JULDAY
#   2. Start retained WRF output at 1980-09-01
#   3. Make yearly files consecutive
#   4. Detect calendar per model:
#        - any yearly file with 366 days -> proleptic_gregorian
#        - all yearly files 365 days     -> 365_day
#   5. Select first soil level if soil_m has a soil-level dimension
#   6. Add XLONG/XLAT from grid.nc before CDO reads the file
#   7. Merge yearly files per model
# ============================================================

BASE_IN="/home/eebiendele/wrf_downscaled/wrf-9km/historical-cmip6/soil_m_d02_hist_bc"
BASE_OUT="/home/eebiendele/wrf_downscaled/wrf-9km/historical-cmip6/soil_fixed"

# Edit this if your grid.nc is somewhere else
GRID_FILE="/home/eebiendele/wrf_downscaled/wrf-9km/historical-cmip6/soil_m_d02_hist_bc/grid.nc"

START_YEAR=1980
END_YEAR=2013

VAR="soil_m"
SCEN="hist"
DOMAIN="d02"

FIRST_START_DATE="1980-09-01"

DELETE_YEARLY_AFTER_MERGE=true
CLEAN_PARTIAL_YEARLY_AT_MODEL_START=true

PYTHON_BIN="${PYTHON_BIN:-python}"

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
# Check required grid file
# ============================================================
if [[ ! -f "$GRID_FILE" ]]; then
  echo "ERROR: GRID_FILE not found:"
  echo "$GRID_FILE"
  echo "Edit GRID_FILE in this script."
  exit 1
fi

# ============================================================
# Check NetCDF file is valid and readable by CDO
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
# Detect soil vertical dimension for soil_m
# Finds the dimension in soil_m(...) that is not day/time/lat/lon.
# ============================================================
get_soil_level_dim() {
  local file="$1"

  "$PYTHON_BIN" - "$file" <<'PY'
import sys
import subprocess
import re

f = sys.argv[1]

try:
    txt = subprocess.check_output(["ncdump", "-h", f], text=True)
except Exception:
    print("")
    sys.exit(0)

# Capture soil_m declaration, including possible line breaks
m = re.search(
    r'\b(?:byte|short|int|float|double)\s+soil_m\s*\((.*?)\)\s*;',
    txt,
    re.S
)

if not m:
    print("")
    sys.exit(0)

dims = [d.strip().replace("\n", "").replace("\t", "") for d in m.group(1).split(",")]

ignore = {
    "day", "time", "time0",
    "lat", "lon", "latitude", "longitude",
    "lat2d", "lon2d",
    "south_north", "west_east",
    "south_north_stag", "west_east_stag",
    "y", "x"
}

candidates = [d for d in dims if d and d not in ignore]

if candidates:
    print(candidates[0])
else:
    print("")
PY
}

# ============================================================
# Add XLAT/XLONG from grid.nc into a NetCDF file
# This fixes missing coordinate references before CDO reads soil_m.
# ============================================================
add_grid_coords() {
  local ncfile="$1"
  local grid_file="$2"

  "$PYTHON_BIN" - "$ncfile" "$grid_file" <<'PY'
import sys
import numpy as np
from netCDF4 import Dataset

ncfile = sys.argv[1]
grid_file = sys.argv[2]

def find_grid_vars(g):
    if "lat2d" in g.variables and "lon2d" in g.variables:
        return "lat2d", "lon2d"
    if "XLAT" in g.variables and "XLONG" in g.variables:
        return "XLAT", "XLONG"
    if "lat" in g.variables and "lon" in g.variables:
        return "lat", "lon"
    raise ValueError("Could not find lat/lon variables in grid file.")

with Dataset(grid_file, "r") as g:
    lat_name, lon_name = find_grid_vars(g)
    lat = np.array(g.variables[lat_name][:], dtype="float32")
    lon = np.array(g.variables[lon_name][:], dtype="float32")

# Remove extra Time dimension if present
if lat.ndim == 3:
    lat = lat[0, :, :]
if lon.ndim == 3:
    lon = lon[0, :, :]

# Convert 1D lat/lon to 2D if needed
if lat.ndim == 1 and lon.ndim == 1:
    lon, lat = np.meshgrid(lon, lat)

if lat.ndim != 2 or lon.ndim != 2:
    raise ValueError(f"Expected 2D lat/lon, got lat={lat.shape}, lon={lon.shape}")

with Dataset(ncfile, "a") as ds:
    if "soil_m" not in ds.variables:
        raise ValueError("soil_m variable not found in file")

    soil = ds.variables["soil_m"]
    dims = soil.dimensions

    if len(dims) < 3:
        raise ValueError(f"soil_m should have at least 3 dimensions after top-layer selection, got {dims}")

    ydim = dims[-2]
    xdim = dims[-1]

    ny = len(ds.dimensions[ydim])
    nx = len(ds.dimensions[xdim])

    if lat.shape != (ny, nx):
        raise ValueError(f"Grid shape mismatch: lat={lat.shape}, file grid={(ny, nx)}")
    if lon.shape != (ny, nx):
        raise ValueError(f"Grid shape mismatch: lon={lon.shape}, file grid={(ny, nx)}")

    # Create or overwrite XLAT
    if "XLAT" not in ds.variables:
        vlat = ds.createVariable("XLAT", "f4", (ydim, xdim))
    else:
        vlat = ds.variables["XLAT"]

    vlat[:, :] = lat
    vlat.units = "degrees_north"
    vlat.standard_name = "latitude"
    vlat.long_name = "latitude"

    # Create or overwrite XLONG
    if "XLONG" not in ds.variables:
        vlon = ds.createVariable("XLONG", "f4", (ydim, xdim))
    else:
        vlon = ds.variables["XLONG"]

    vlon[:, :] = lon
    vlon.units = "degrees_east"
    vlon.standard_name = "longitude"
    vlon.long_name = "longitude"

    # Make soil_m point to real coordinate variables
    # Use XLONG XLAT because your file was looking for XLONG first.
    soil.coordinates = "XLONG XLAT"

print("Added XLONG/XLAT from grid file successfully")
PY
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

  "$PYTHON_BIN" - <<PY
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

  "$PYTHON_BIN" - <<PY
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
# Main loop
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
    echo "ERROR: missing model folder: $INDIR" >&2
    exit 1
  fi

  MODEL_CALENDAR=$(detect_model_calendar "$MODEL" "$RUN" "$INDIR")

  if [[ "$MODEL_CALENDAR" == "unknown" ]]; then
    echo "ERROR: could not detect calendar for $MODEL" >&2
    exit 1
  fi

  echo "Detected calendar for $MODEL: $MODEL_CALENDAR"

  if check_nc "$merged_out" >/dev/null 2>&1; then
    echo "Merged file already exists and is valid. Skipping model: $MODEL"
    continue
  fi

  rm -f "${OUTDIR}"/.${VAR}_${MODEL}_*.tmp.nc
  rm -f "$tmp_merged"

  if [[ "$CLEAN_PARTIAL_YEARLY_AT_MODEL_START" == true ]]; then
    echo "Cleaning partial yearly corrected files for model: $MODEL"
    rm -f "${OUTDIR}/${VAR}_${MODEL}_"[0-9][0-9][0-9][0-9].nc
  fi

  current_start_date="$FIRST_START_DATE"

  # ============================================================
  # Process yearly files
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
    lev="${tmpdir}/_lev.nc"
    lev2d="${tmpdir}/_lev2d.nc"
    b="${tmpdir}/_b.nc"
    c="${tmpdir}/_c.nc"
    clean="${tmpdir}/_clean.nc"
    hdr="${tmpdir}/header.txt"

    cleanup() {
      rm -rf "$tmpdir"
      rm -f "$tmp_out"
    }
    trap cleanup EXIT

    cp -f "$in" "$a"

    # ------------------------------------------------------------
    # 1) Select first soil level if soil_m has a soil-level dimension
    # ------------------------------------------------------------
    soil_dim=$(get_soil_level_dim "$a")

    if [[ -n "$soil_dim" ]]; then
      echo "Detected soil level dimension: $soil_dim"
      echo "Selecting first soil level: ${soil_dim}=0"

      if ! ncks -O -d "$soil_dim",0,0 "$a" "$lev"; then
        echo "ERROR: failed to select first soil level in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi

      echo "Removing singleton soil level dimension"

      if ! ncwa -O -a "$soil_dim" "$lev" "$lev2d"; then
        echo "ERROR: failed to remove soil level dimension in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    else
      echo "No extra soil level dimension detected. Using file as-is."
      cp -f "$a" "$lev2d"
    fi

    ncdump -h "$lev2d" > "$hdr"

    # ------------------------------------------------------------
    # 2) Move existing time dimension/variable out of the way
    # ------------------------------------------------------------
    if grep -qE '^[[:space:]]*time[[:space:]]*=' "$hdr"; then
      echo "Renaming dimension: time -> time0"
      if ! ncrename -O -d time,time0 "$lev2d"; then
        echo "ERROR: failed to rename time dimension in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    fi

    ncdump -h "$lev2d" > "$hdr"

    if grep -qE '^[[:space:]]*(double|float|int|short|byte|char)[[:space:]]+time\(' "$hdr"; then
      echo "Renaming variable: time -> time0"
      if ! ncrename -O -v time,time0 "$lev2d"; then
        echo "ERROR: failed to rename time variable in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    fi

    ncdump -h "$lev2d" > "$hdr"

    # ------------------------------------------------------------
    # 3) Rename day dimension to time
    # ------------------------------------------------------------
    if grep -qE '^[[:space:]]*day[[:space:]]*=' "$hdr"; then
      echo "Renaming dimension: day -> time"
      if ! ncrename -O -d day,time "$lev2d" "$b"; then
        echo "ERROR: failed to rename day dimension in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    else
      echo "ERROR: no day dimension found in: $in" >&2
      echo "Header dimensions are:" >&2
      grep -E '^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=' "$hdr" >&2 || true
      trap - EXIT
      cleanup
      exit 1
    fi

    ncdump -h "$b" > "$hdr"

    if grep -qE '^[[:space:]]*(double|float|int|short|byte|char)[[:space:]]+day\(' "$hdr"; then
      echo "Renaming variable: day -> time"
      if ! ncrename -O -v day,time "$b"; then
        echo "ERROR: failed to rename day variable in: $in" >&2
        trap - EXIT
        cleanup
        exit 1
      fi
    fi

    # ------------------------------------------------------------
    # 4) Make time unlimited
    # ------------------------------------------------------------
    echo "Making time record dimension"

    if ! ncks -O --mk_rec_dmn time "$b" "$c"; then
      echo "ERROR: failed to make time record dimension: $in" >&2
      trap - EXIT
      cleanup
      exit 1
    fi

    # ------------------------------------------------------------
    # 5) Add XLONG/XLAT from grid.nc before CDO reads the file
    # ------------------------------------------------------------
    echo "Adding XLONG/XLAT from grid file before CDO"
    echo "Grid file: $GRID_FILE"

    cp -f "$c" "$clean"

    if ! add_grid_coords "$clean" "$GRID_FILE"; then
      echo "ERROR: failed to add XLONG/XLAT from $GRID_FILE" >&2
      trap - EXIT
      cleanup
      exit 1
    fi

    # Remove grid_mapping if it points to missing projection metadata
    ncatted -O -a grid_mapping,soil_m,d,, "$clean" || true

    # ------------------------------------------------------------
    # 6) Assign consecutive daily time axis
    # ------------------------------------------------------------
    echo "Setting consecutive time axis"

    if ! cdo -O \
        -settaxis,"${current_start_date}",00:00:00,1day \
        -setcalendar,"${MODEL_CALENDAR}" \
        -settunits,days \
        "$clean" "$tmp_out"; then

      echo "ERROR: CDO time-axis setting failed for: $in" >&2
      trap - EXIT
      cleanup
      exit 1
    fi

    # ------------------------------------------------------------
    # Validate yearly output
    # ------------------------------------------------------------
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
  # Merge yearly files
  # ============================================================
  echo "------------------------------------------------------------"
  echo "Merging yearly files for model: $MODEL"
  echo "Merged output: $merged_out"

  rm -f "$tmp_merged"

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
    mv -f "$tmp_merged" "$merged_out"
    echo "Merged file written: $merged_out"
  else
    echo "ERROR: merged file failed validation for $MODEL" >&2
    rm -f "$tmp_merged"
    exit 1
  fi

  echo -n "Merged ntime: "
  cdo -s ntime "$merged_out"

  print_first_last_dates "$merged_out"

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
