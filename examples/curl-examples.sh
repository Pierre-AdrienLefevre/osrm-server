#!/bin/bash

# =============================================================================
# OSRM API request examples
# =============================================================================
#
# Prerequisites: a running OSRM server (./start.sh canada)
# Default port: 5001 (Canada)
#
# Usage:
#   ./examples/curl-examples.sh          # Run all examples
#   ./examples/curl-examples.sh 5002     # Use a specific port
#
# =============================================================================

PORT="${1:-5001}"
BASE="http://localhost:$PORT"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== OSRM API Examples (port $PORT) ===${NC}\n"

# -----------------------------------------------------------------------------
# 1. Route - Calculate a route
# -----------------------------------------------------------------------------
echo -e "${GREEN}1. Route: Montreal -> Quebec City${NC}"
echo "   Calculates the optimal route between two points"
echo ""
curl -s "$BASE/route/v1/driving/-73.5673,45.5017;-71.2080,46.8139?overview=full&geometries=geojson&steps=true" | python3 -m json.tool 2>/dev/null || curl -s "$BASE/route/v1/driving/-73.5673,45.5017;-71.2080,46.8139?overview=full&geometries=geojson&steps=true"
echo -e "\n"

# -----------------------------------------------------------------------------
# 2. Route - With alternatives
# -----------------------------------------------------------------------------
echo -e "${GREEN}2. Route with alternatives: Montreal -> Ottawa${NC}"
echo "   Returns multiple possible routes"
echo ""
curl -s "$BASE/route/v1/driving/-73.5673,45.5017;-75.6972,45.4215?alternatives=3&overview=full&geometries=geojson" | python3 -m json.tool 2>/dev/null || curl -s "$BASE/route/v1/driving/-73.5673,45.5017;-75.6972,45.4215?alternatives=3&overview=full&geometries=geojson"
echo -e "\n"

# -----------------------------------------------------------------------------
# 3. Table - Distance/duration matrix
# -----------------------------------------------------------------------------
echo -e "${GREEN}3. Table: 3x3 matrix (Montreal, Quebec, Ottawa)${NC}"
echo "   Calculates durations between all pairs of points"
echo ""
curl -s "$BASE/table/v1/driving/-73.5673,45.5017;-71.2080,46.8139;-75.6972,45.4215?annotations=duration,distance" | python3 -m json.tool 2>/dev/null || curl -s "$BASE/table/v1/driving/-73.5673,45.5017;-71.2080,46.8139;-75.6972,45.4215?annotations=duration,distance"
echo -e "\n"

# -----------------------------------------------------------------------------
# 4. Nearest - Closest point on the road network
# -----------------------------------------------------------------------------
echo -e "${GREEN}4. Nearest: 3 closest points (Montreal)${NC}"
echo "   Finds the nearest road nodes to a coordinate"
echo ""
curl -s "$BASE/nearest/v1/driving/-73.5673,45.5017?number=3" | python3 -m json.tool 2>/dev/null || curl -s "$BASE/nearest/v1/driving/-73.5673,45.5017?number=3"
echo -e "\n"

# -----------------------------------------------------------------------------
# 5. Trip - Route optimization (TSP)
# -----------------------------------------------------------------------------
echo -e "${GREEN}5. Trip: Optimal tour (Montreal -> Quebec -> Ottawa -> back)${NC}"
echo "   Solves the traveling salesman problem"
echo ""
curl -s "$BASE/trip/v1/driving/-73.5673,45.5017;-71.2080,46.8139;-75.6972,45.4215?roundtrip=true&geometries=geojson" | python3 -m json.tool 2>/dev/null || curl -s "$BASE/trip/v1/driving/-73.5673,45.5017;-71.2080,46.8139;-75.6972,45.4215?roundtrip=true&geometries=geojson"
echo -e "\n"

# -----------------------------------------------------------------------------
# 6. Match - Map matching (GPS traces -> route)
# -----------------------------------------------------------------------------
echo -e "${GREEN}6. Match: GPS trace on road network (Montreal)${NC}"
echo "   Snaps raw GPS points to existing roads"
echo ""
curl -s "$BASE/match/v1/driving/-73.5673,45.5017;-73.5600,45.5050;-73.5534,45.5088?timestamps=0;1;2&geometries=geojson" | python3 -m json.tool 2>/dev/null || curl -s "$BASE/match/v1/driving/-73.5673,45.5017;-73.5600,45.5050;-73.5534,45.5088?timestamps=0;1;2&geometries=geojson"
echo -e "\n"

echo -e "${CYAN}=== End of examples ===${NC}"
echo -e "OSRM documentation: http://project-osrm.org/docs/v5/api/"
