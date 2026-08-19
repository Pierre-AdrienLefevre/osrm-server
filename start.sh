#!/bin/bash

# =============================================================================
# Start OSRM servers and verify connectivity
# =============================================================================
#
# Usage:
#   ./start.sh              # Start all active services
#   ./start.sh canada       # Start only osrm-canada
#
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Region ports (must match docker-compose.yml)
ALL_REGIONS="canada quebec netherlands australia italy"
get_region_port() {
    case "$1" in
        canada)      echo 5001 ;;
        quebec)      echo 5002 ;;
        netherlands) echo 5004 ;;
        australia)   echo 5005 ;;
        italy)       echo 5006 ;;
        *)           echo "" ;;
    esac
}

SERVICE="$1"

# Start
echo -e "${YELLOW}Starting OSRM servers...${NC}"
if [ -n "$SERVICE" ]; then
    docker compose up -d "osrm-$SERVICE"
else
    docker compose up -d
fi

# Wait
echo "Waiting for startup (5s)..."
sleep 5

# Connectivity test
test_region() {
    local region=$1
    local port=$2
    echo -ne "  $region (port $port): "
    if curl -sf "http://localhost:$port/route/v1/driving/-73.5673,45.5017;-73.5534,45.5088?overview=false" > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo -e "    Check logs: ${YELLOW}docker compose logs osrm-$region${NC}"
    fi
}

echo -e "\n${YELLOW}Connectivity test:${NC}"
if [ -n "$SERVICE" ]; then
    port="$(get_region_port "$SERVICE")"
    if [ -n "$port" ]; then
        test_region "$SERVICE" "$port"
    fi
else
    for region in $ALL_REGIONS; do
        container="osrm-$region"
        if docker ps --format '{{.Names}}' | grep -q "^$container$"; then
            test_region "$region" "$(get_region_port "$region")"
        fi
    done
fi

echo -e "\n${GREEN}Useful commands:${NC}"
echo -e "  Status : ${YELLOW}docker compose ps${NC}"
echo -e "  Logs   : ${YELLOW}docker compose logs -f${NC}"
echo -e "  Stop   : ${YELLOW}docker compose down${NC}"
echo -e "  Restart: ${YELLOW}docker compose restart${NC}"
