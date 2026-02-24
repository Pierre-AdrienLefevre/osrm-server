#!/bin/bash

# =============================================================================
# Stop OSRM servers
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
NC='\033[0m'

echo "Stopping OSRM servers..."
docker compose down

echo -e "${GREEN}OSRM servers stopped.${NC}"
