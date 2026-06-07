#!/bin/bash

REMOTE_USER="eebiendele"
REMOTE_HOST="aeroclimate.ucmerced.edu"

REMOTE_BASE="/home/eebiendele/wrf_downscaled/wrf-9km/historical-cmip6/wspd_fixed"

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

for MODEL in "${MODELS[@]}"; do
  echo "Copying $MODEL..."

  scp "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE}/${MODEL}/wspd10max_${MODEL}_hist.nc" .

done
