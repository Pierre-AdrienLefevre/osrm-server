#!/bin/bash

# =============================================================================
# Display OSRM server status
# =============================================================================
#
# Usage:
#   ./status.sh           # Status of all OSRM servers
#
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ALL_REGIONS="canada quebec usa netherlands australia"
get_region_port() {
    case "$1" in
        canada)      echo 5001 ;;
        quebec)      echo 5002 ;;
        usa)         echo 5003 ;;
        netherlands) echo 5004 ;;
        australia)   echo 5005 ;;
        *)           echo "" ;;
    esac
}

echo -e "${CYAN}=== OSRM Server - Status ===${NC}\n"

# Check Docker
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Docker is not running or not installed${NC}"
    exit 1
fi

# Count active services
active=0
inactive=0

for region in $ALL_REGIONS; do
    container="osrm-$region"
    port="$(get_region_port "$region")"

    echo -ne "  $region (port $port): "

    # Check if container is running
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        # Get container info
        uptime=$(docker ps --filter "name=^${container}$" --format '{{.Status}}' 2>/dev/null)
        mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$container" 2>/dev/null)

        echo -ne "${GREEN}RUNNING${NC}"
        echo -ne "  |  $uptime"
        if [ -n "$mem" ]; then
            echo -ne "  |  RAM: $mem"
        fi
        echo ""

        # Connectivity test
        echo -ne "    Connectivity: "
        if curl -sf --max-time 5 "http://localhost:$port/route/v1/driving/-73.5673,45.5017;-73.5534,45.5088?overview=false" > /dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}Waiting (server starting...)${NC}"
        fi

        active=$((active + 1))
    else
        # Check if data exists
        if [ -d "$SCRIPT_DIR/regions/$region" ] && [ -f "$SCRIPT_DIR/regions/$region/${region}-latest.osrm" ]; then
            echo -e "${YELLOW}STOPPED${NC} (data present, ready to start)"
        else
            echo -e "${RED}NOT CONFIGURED${NC} (run: ./setup.sh $region)"
        fi
        inactive=$((inactive + 1))
    fi
done

echo ""
echo -e "${CYAN}Summary: ${GREEN}$active running${NC}, ${YELLOW}$inactive inactive${NC}"

if [ "$active" -eq 0 ]; then
    echo -e "\nStart a server with: ${YELLOW}./start.sh <region>${NC}"
fi
