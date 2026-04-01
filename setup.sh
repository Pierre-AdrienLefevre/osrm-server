#!/bin/bash

# =============================================================================
# Setup OSRM - Download and prepare data for a region
# =============================================================================
#
# Usage:
#   ./setup.sh canada          # Download and prepare Canada
#   ./setup.sh quebec          # Download and prepare Quebec
#   ./setup.sh <region>        # Download and prepare a custom region
#
# Pre-configured regions:
#   canada       -> https://download.geofabrik.de/north-america/canada-latest.osm.pbf
#   quebec       -> https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf
#   usa          -> https://download.geofabrik.de/north-america/us-latest.osm.pbf
#   netherlands  -> https://download.geofabrik.de/europe/netherlands-latest.osm.pbf
#   australia    -> https://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf
#
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

OSRM_IMAGE="ghcr.io/project-osrm/osrm-backend:v6.0.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGIONS_DIR="$SCRIPT_DIR/regions"

# Pre-configured region URLs
get_region_url() {
    case "$1" in
        canada)      echo "https://download.geofabrik.de/north-america/canada-latest.osm.pbf" ;;
        quebec)      echo "https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf" ;;
        usa)         echo "https://download.geofabrik.de/north-america/us-latest.osm.pbf" ;;
        netherlands) echo "https://download.geofabrik.de/europe/netherlands-latest.osm.pbf" ;;
        australia)   echo "https://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf" ;;
        *)           echo "" ;;
    esac
}

# =============================================================================
# Argument validation
# =============================================================================
if [ -z "$1" ]; then
    echo -e "${RED}Usage: ./setup.sh <region>${NC}"
    echo -e "Available regions: ${GREEN}canada${NC}, ${GREEN}quebec${NC}, ${GREEN}usa${NC}, ${GREEN}netherlands${NC}, ${GREEN}australia${NC}"
    echo -e "Or provide a custom URL: ${YELLOW}./setup.sh my-region https://url/to/file.osm.pbf${NC}"
    exit 1
fi

REGION="$1"
DATA_DIR="$REGIONS_DIR/$REGION"
OSM_FILE="${REGION}-latest.osm.pbf"

# Determine URL
if [ -n "$2" ]; then
    OSM_URL="$2"
elif [ -n "$(get_region_url "$REGION")" ]; then
    OSM_URL="$(get_region_url "$REGION")"
else
    echo -e "${RED}Region '$REGION' not recognized and no URL provided.${NC}"
    echo -e "Usage: ./setup.sh $REGION https://download.geofabrik.de/...osm.pbf"
    exit 1
fi

# =============================================================================
# Checks
# =============================================================================
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running or not installed${NC}"
    exit 1
fi

echo -e "${GREEN}=== OSRM Setup: $REGION ===${NC}"
echo -e "Directory: $DATA_DIR"
echo -e "Source   : $OSM_URL\n"

mkdir -p "$DATA_DIR"

# =============================================================================
# Step 1: Download
# =============================================================================
echo -e "${YELLOW}Step 1/4: Downloading OSM data${NC}"
if [ -f "$DATA_DIR/$OSM_FILE" ]; then
    echo "File $OSM_FILE already exists."
    read -p "Re-download? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}-> Existing file kept${NC}\n"
    else
        curl -L -o "$DATA_DIR/$OSM_FILE" "$OSM_URL"
        echo -e "${GREEN}-> Download complete${NC}\n"
    fi
else
    echo "Downloading (this may take several minutes)..."
    curl -L -o "$DATA_DIR/$OSM_FILE" "$OSM_URL"
    echo -e "${GREEN}-> Download complete${NC}\n"
fi

# =============================================================================
# Step 2: Extract
# =============================================================================
OSRM_FILE="$DATA_DIR/${REGION}-latest.osrm"
if [ -f "$OSRM_FILE" ]; then
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

echo -e "${YELLOW}Step 2/4: Extraction (10-20 minutes)${NC}"
docker run -t --rm \
    -v "$DATA_DIR:/data" \
    "$OSRM_IMAGE" \
    osrm-extract -p /opt/car.lua "/data/$OSM_FILE"
echo -e "${GREEN}-> Extraction complete${NC}\n"

# =============================================================================
# Step 3: Partition (MLD)
# =============================================================================
echo -e "${YELLOW}Step 3/4: Partition (5-10 minutes)${NC}"
docker run -t --rm \
    -v "$DATA_DIR:/data" \
    "$OSRM_IMAGE" \
    osrm-partition "/data/${REGION}-latest.osrm"
echo -e "${GREEN}-> Partition complete${NC}\n"

# =============================================================================
# Step 4: Customize
# =============================================================================
echo -e "${YELLOW}Step 4/4: Customization${NC}"
docker run -t --rm \
    -v "$DATA_DIR:/data" \
    "$OSRM_IMAGE" \
    osrm-customize "/data/${REGION}-latest.osrm"
echo -e "${GREEN}-> Customization complete${NC}\n"

# =============================================================================
# Done
# =============================================================================
echo -e "${GREEN}=== Setup complete for $REGION ===${NC}"
echo -e "\nStart the server with:"
echo -e "  ${YELLOW}cd $SCRIPT_DIR && docker compose up -d${NC}"
echo -e "\nOr a single service:"
echo -e "  ${YELLOW}docker compose up -d osrm-${REGION}${NC}"
