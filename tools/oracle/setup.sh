#!/bin/sh
# Prepares the pinned, patched BedSim checkout used as the differential oracle.
set -eu
cd "$(dirname "$0")"
rm -rf .bedsim
git clone -q https://github.com/oomph-ac/bedsim .bedsim
git -C .bedsim checkout -q 9c12b344afdea7939b983fa15a762592aa179351
git -C .bedsim apply ../oracle.patch
echo "oracle ready: run 'go run . -out ../../tests/fixtures/bedsim.json'"
