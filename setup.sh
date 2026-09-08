#!/bin/bash

# =============================================================================
# Setup OSRM - Download and prepare data for a region
# =============================================================================
#
# Usage:
#   ./setup.sh canada          # Download and prepare Canada (CH)
#   ./setup.sh canada mld      # Same region, MLD algorithm
#   ./setup.sh <region>        # Download and prepare a custom region
#
# The .pbf is shared at regions/<region>/, generated data goes to
# regions/<region>/ch/ or regions/<region>/mld/. CH and MLD share no generated
# file, so each directory holds its own extraction and is self-contained.
#
# Pre-configured regions:
#   canada       -> https://download.geofabrik.de/north-america/canada-latest.osm.pbf
#   quebec       -> https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf
#   usa          -> https://download.geofabrik.de/north-america/us-latest.osm.pbf
#   netherlands  -> https://download.geofabrik.de/europe/netherlands-latest.osm.pbf
#   australia    -> https://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf
#   italy        -> https://download.geofabrik.de/europe/italy-latest.osm.pbf
#
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

OSRM_IMAGE="ghcr.io/project-osrm/osrm-backend:v26.9.0-arm64-debian"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGIONS_DIR="$SCRIPT_DIR/regions"

# Processing backend: "docker" (default) or "native".
# Set by ./configure.sh, overridable with OSRM_BACKEND=native ./setup.sh <region>
if [ -z "${OSRM_BACKEND:-}" ]; then
    if [ -f "$SCRIPT_DIR/.osrm-backend" ]; then
        OSRM_BACKEND="$(tr -d '[:space:]' < "$SCRIPT_DIR/.osrm-backend")"
    else
        OSRM_BACKEND="docker"
    fi
fi

# Extraction needs roughly 2x the PBF size in RAM. If the Docker VM is smaller
# than that, borrow host memory for the run and give it back afterwards.
BOOSTED=0
maybe_boost_ram() {
    [ "$OSRM_BACKEND" = "docker" ] || return 0
    [ -x "$SCRIPT_DIR/configure.sh" ] || return 0

    local pbf="$REGION_DIR/$OSM_FILE"
    [ -f "$pbf" ] || return 0

    local pbf_mib needed_mib have_mib
    pbf_mib=$(( $(wc -c < "$pbf" | tr -d ' ') / 1048576 ))
    needed_mib=$(( pbf_mib * 2 ))
    have_mib=$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1/1048576}')

    if [ -n "$have_mib" ] && [ "$needed_mib" -gt "$have_mib" ]; then
        echo -e "${YELLOW}Region needs ~${needed_mib} MiB but Docker has ${have_mib} MiB.${NC}"
        if "$SCRIPT_DIR/configure.sh" --boost; then
            BOOSTED=1
        else
            echo -e "${YELLOW}Boost failed; continuing (extraction may be OOM-killed).${NC}"
        fi
        echo ""
    fi
}

# Give the borrowed memory back, whether we finished or were interrupted.
restore_ram() {
    if [ "$BOOSTED" -eq 1 ]; then
        BOOSTED=0
        echo -e "\n${YELLOW}Returning memory to the host...${NC}"
        "$SCRIPT_DIR/configure.sh" --restore || true
    fi
}
trap restore_ram EXIT INT TERM

# Run an OSRM tool through the selected backend.
# Paths are expressed as /data/<file> and rewritten for native runs.
osrm_run() {
    local tool="$1"; shift
    if [ "$OSRM_BACKEND" = "native" ]; then
        if ! command -v "$tool" > /dev/null 2>&1; then
            echo -e "${RED}$tool not found. Run ./configure.sh --native${NC}"
            exit 1
        fi
        local args=()
        local a
        for a in "$@"; do
            case "$a" in
                /data/*) args+=("$DATA_DIR/${a#/data/}") ;;
                /pbf/*)  args+=("$REGION_DIR/${a#/pbf/}") ;;
                /opt/*)  args+=("$SCRIPT_DIR/profiles/${a#/opt/}") ;;
                *)       args+=("$a") ;;
            esac
        done
        "$tool" "${args[@]}"
    else
        # The .pbf sits at the region root, the generated files in the algorithm
        # subdirectory: mount both so osrm-extract can read one and write the other.
        docker run -t --rm \
            -v "$DATA_DIR:/data" \
            -v "$REGION_DIR:/pbf" \
            "$OSRM_IMAGE" "$tool" "$@"
    fi
}

# Pre-configured region URLs
get_region_url() {
    case "$1" in
        canada)      echo "https://download.geofabrik.de/north-america/canada-latest.osm.pbf" ;;
        quebec)      echo "https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf" ;;
        usa)         echo "https://download.geofabrik.de/north-america/us-latest.osm.pbf" ;;
        netherlands) echo "https://download.geofabrik.de/europe/netherlands-latest.osm.pbf" ;;
        australia)   echo "https://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf" ;;
        italy)       echo "https://download.geofabrik.de/europe/italy-latest.osm.pbf" ;;
        *)           echo "" ;;
    esac
}

# Number of parallel connections for downloads (Geofabrik throttles per connection)
DOWNLOAD_CONNECTIONS="${DOWNLOAD_CONNECTIONS:-6}"

# Download a file using parallel HTTP range requests.
# Falls back to a single connection if the server does not support ranges.
# Usage: download_osm <url> <output-file>
download_osm() {
    local url="$1"
    local out="$2"
    local parts_dir="${out}.parts"

    # Probe the server: total size and range support
    local headers size accept_ranges
    headers="$(curl -sIL "$url" 2>/dev/null)"
    size="$(echo "$headers" | awk 'tolower($1) ~ /^content-length:/ {print $2}' | tr -d '\r' | tail -1)"
    accept_ranges="$(echo "$headers" | awk 'tolower($1) ~ /^accept-ranges:/ {print tolower($2)}' | tr -d '\r' | tail -1)"

    if [ "$accept_ranges" != "bytes" ] || [ -z "$size" ] || [ "$size" -lt 10485760 ] 2>/dev/null; then
        echo "  (single connection)"
        curl -L --retry 3 --retry-delay 2 -o "$out" "$url"
        return
    fi

    local n="$DOWNLOAD_CONNECTIONS"
    echo "  Size: $((size / 1048576)) MB, $n parallel connections"
    rm -rf "$parts_dir"; mkdir -p "$parts_dir"

    local chunk=$((size / n))
    local pids="" i start end
    for i in $(seq 0 $((n - 1))); do
        start=$((i * chunk))
        if [ "$i" -eq $((n - 1)) ]; then end=$((size - 1)); else end=$((start + chunk - 1)); fi
        curl -sL --retry 3 --retry-delay 2 -r "${start}-${end}" -o "$parts_dir/part.$i" "$url" &
        pids="${pids:+$pids }$!"
    done

    # Progress while the parts download
    ( first_pid="${pids%% *}"
      while kill -0 "$first_pid" 2>/dev/null; do
          done_bytes=$(cat "$parts_dir"/part.* 2>/dev/null | wc -c | tr -d ' ')
          printf "\r  Downloaded: %s / %s MB" "$((done_bytes / 1048576))" "$((size / 1048576))"
          sleep 2
      done ) &
    local progress_pid=$!

    local failed=0
    for pid in $pids; do wait "$pid" || failed=1; done
    kill "$progress_pid" 2>/dev/null; wait "$progress_pid" 2>/dev/null
    printf "\r"

    if [ "$failed" -ne 0 ]; then
        echo -e "${YELLOW}  Parallel download failed, retrying with a single connection${NC}"
        rm -rf "$parts_dir"
        curl -L --retry 3 --retry-delay 2 -o "$out" "$url"
        return
    fi

    # Reassemble, then verify the size matches what the server announced
    cat "$parts_dir"/part.* > "$out"
    rm -rf "$parts_dir"

    local actual
    actual=$(wc -c < "$out" | tr -d ' ')
    if [ "$actual" -ne "$size" ]; then
        echo -e "${RED}  Size mismatch: got $actual, expected $size. Retrying with a single connection${NC}"
        curl -L --retry 3 --retry-delay 2 -o "$out" "$url"
    fi
}

# =============================================================================
# Argument validation
# =============================================================================
# --clean / --purge: wipe a region without re-processing it.
#   --clean <region>   remove generated .osrm.* files, keep the .pbf
#   --purge <region>   remove everything, .pbf included (forces a re-download)
if [ "$1" = "--clean" ] || [ "$1" = "--purge" ]; then
    mode="$1"
    if [ -z "$2" ]; then
        echo -e "${RED}Usage: ./setup.sh $mode <region>${NC}"
        exit 1
    fi
    target="$REGIONS_DIR/$2"
    if [ ! -d "$target" ]; then
        echo -e "${RED}No data for region '$2' ($target)${NC}"
        exit 1
    fi
    if [ "$mode" = "--purge" ]; then
        echo -e "${YELLOW}Removing every file for '$2', .pbf included${NC}"
        rm -rf "$target"
    else
        # Optional third argument restricts the cleanup to one algorithm.
        if [ "$3" = "ch" ] || [ "$3" = "mld" ]; then
            echo -e "${YELLOW}Removing the '$3' data for '$2' (the .pbf is kept)${NC}"
            rm -rf "${target:?}/$3"
        else
            echo -e "${YELLOW}Removing the ch and mld data for '$2' (the .pbf is kept)${NC}"
            rm -rf "${target:?}/ch" "${target:?}/mld"
            # Files from the previous flat layout, if any.
            find "$target" -maxdepth 1 -name "$2-latest.osrm*" -delete 2>/dev/null
        fi
    fi
    echo -e "${GREEN}-> Done${NC}"
    exit 0
fi

if [ -z "$1" ]; then
    echo -e "${RED}Usage: ./setup.sh <region>${NC}"
    echo -e "Available regions: ${GREEN}canada${NC}, ${GREEN}quebec${NC}, ${GREEN}usa${NC}, ${GREEN}netherlands${NC}, ${GREEN}australia${NC}, ${GREEN}italy${NC}"
    echo -e "Or provide a custom URL: ${YELLOW}./setup.sh my-region https://url/to/file.osm.pbf${NC}"
    echo -e "\nAlgorithm (data goes to regions/<region>/<algorithm>/):"
    echo -e "  ${YELLOW}./setup.sh <region>${NC}           CH (default)"
    echo -e "  ${YELLOW}./setup.sh <region> mld${NC}       MLD"
    echo -e "\nCleanup:"
    echo -e "  ${YELLOW}./setup.sh --clean <region>${NC}       remove ch and mld, keep the .pbf"
    echo -e "  ${YELLOW}./setup.sh --clean <region> ch${NC}    remove only ch"
    echo -e "  ${YELLOW}./setup.sh --purge <region>${NC}       remove everything, .pbf included"
    exit 1
fi

REGION="$1"

# Algorithm: "ch" (default) or "mld". Accepted as $2, or as $3 after a custom URL.
# CH and MLD share the .pbf but nothing else, so each gets its own directory:
# the extraction is redone per algorithm rather than shared, which keeps every
# directory self-contained and directly mountable in Docker.
ALGORITHM="ch"
OSM_URL=""
for arg in "$2" "$3"; do
    case "$arg" in
        "")        ;;
        ch|mld)    ALGORITHM="$arg" ;;
        *)         OSM_URL="$arg" ;;
    esac
done

# .pbf lives at the region root (shared); generated files go under the algorithm.
REGION_DIR="$REGIONS_DIR/$REGION"
DATA_DIR="$REGION_DIR/$ALGORITHM"
OSM_FILE="${REGION}-latest.osm.pbf"

# Determine URL
if [ -z "$OSM_URL" ]; then
    OSM_URL="$(get_region_url "$REGION")"
fi
if [ -z "$OSM_URL" ]; then
    echo -e "${RED}Region '$REGION' not recognized and no URL provided.${NC}"
    echo -e "Usage: ./setup.sh $REGION https://download.geofabrik.de/...osm.pbf"
    exit 1
fi

# =============================================================================
# Checks
# =============================================================================
if [ "$OSRM_BACKEND" = "docker" ] && ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running or not installed${NC}"
    echo -e "Start Docker Desktop, or switch backend with ${YELLOW}./configure.sh${NC}"
    exit 1
fi

echo -e "${GREEN}=== OSRM Setup: $REGION ===${NC}"
echo -e "Directory: $DATA_DIR"
echo -e "Algorithm: $ALGORITHM"
echo -e "Source   : $OSM_URL"
echo -e "Backend  : $OSRM_BACKEND\n"

mkdir -p "$REGION_DIR" "$DATA_DIR"

# =============================================================================
# Step 1: Download
# =============================================================================
echo -e "${YELLOW}Step 1/3: Downloading OSM data${NC}"
if [ -f "$REGION_DIR/$OSM_FILE" ]; then
    echo "File $OSM_FILE already exists."
    read -p "Re-download? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}-> Existing file kept${NC}\n"
    else
        download_osm "$OSM_URL" "$REGION_DIR/$OSM_FILE"
        echo -e "${GREEN}-> Download complete${NC}\n"
    fi
else
    echo "Downloading (this may take several minutes)..."
    download_osm "$OSM_URL" "$REGION_DIR/$OSM_FILE"
    echo -e "${GREEN}-> Download complete${NC}\n"
fi

# =============================================================================
# Step 2: Extract
# =============================================================================
# OSRM writes many .osrm.* files, never a bare .osrm -- detect the set, not one name.
if compgen -G "$DATA_DIR/${REGION}-latest.osrm.*" > /dev/null; then
    echo "OSRM files already exist."
    read -p "Re-generate? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}-> Existing files kept${NC}\n"
        echo -e "${GREEN}=== Setup complete for $REGION ===${NC}"
        echo -e "Start the server with: ${YELLOW}docker compose up -d${NC}"
        exit 0
    fi
fi

# Always start from a clean slate: leftovers from another algorithm (MLD .cells,
# .partition, .mldgr...), another OSRM version or another platform are silently
# reloaded by osrm-routed and make it fail with a fingerprint or platform error.
# The .pbf is kept -- it is the only file we would have to download again.
clean_generated() {
    local removed
    removed=$(find "$DATA_DIR" -maxdepth 1 -name "${REGION}-latest.osrm*" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$removed" -gt 0 ]; then
        echo -e "${YELLOW}Removing $removed previously generated file(s) (the .pbf is kept)${NC}"
        find "$DATA_DIR" -maxdepth 1 -name "${REGION}-latest.osrm*" -delete
    fi
}
clean_generated

maybe_boost_ram

echo -e "${YELLOW}Step 2/3: Extraction (10-20 minutes)${NC}"
osrm_run osrm-extract -p /opt/car.lua --output "/data/${REGION}-latest.osrm" "/pbf/$OSM_FILE"
echo -e "${GREEN}-> Extraction complete${NC}\n"

# =============================================================================
# Step 3: Index the graph -- CH (one pass) or MLD (partition + customize)
# =============================================================================
if [ "$ALGORITHM" = "ch" ]; then
    echo -e "${YELLOW}Step 3/3: Contraction (20-40 minutes)${NC}"
    osrm_run osrm-contract "/data/${REGION}-latest.osrm"
    echo -e "${GREEN}-> Contraction complete${NC}\n"
else
    echo -e "${YELLOW}Step 3/3: Partition + customization (10-20 minutes)${NC}"
    osrm_run osrm-partition "/data/${REGION}-latest.osrm"
    osrm_run osrm-customize "/data/${REGION}-latest.osrm"
    echo -e "${GREEN}-> Partition and customization complete${NC}\n"
fi

# =============================================================================
# Done
# =============================================================================
echo -e "${GREEN}=== Setup complete for $REGION ($ALGORITHM) ===${NC}"
echo -e "Data: ${YELLOW}$DATA_DIR${NC}"
echo -e "docker-compose.yml must mount ./regions/$REGION/$ALGORITHM and use --algorithm $ALGORITHM"
echo -e "\nStart the server with:"
echo -e "  ${YELLOW}cd $SCRIPT_DIR && docker compose up -d${NC}"
echo -e "\nOr a single service:"
echo -e "  ${YELLOW}docker compose up -d osrm-${REGION}${NC}"
