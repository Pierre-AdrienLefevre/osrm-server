#!/bin/bash

# =============================================================================
# Configure the OSRM processing backend (Docker or native)
# =============================================================================
#
# OSRM data preparation (osrm-extract) is memory hungry: a large region such as
# Canada needs far more RAM than Docker Desktop allocates by default. This
# script picks a backend that can actually complete the job.
#
# Usage:
#   ./configure.sh            # Interactive: inspect, then choose a backend
#   ./configure.sh --status   # Report the current setup, change nothing
#   ./configure.sh --docker   # Use Docker, raising its RAM if needed
#   ./configure.sh --native   # Use native binaries (Homebrew)
#   ./configure.sh --boost    # Temporarily give Docker most of the host RAM
#   ./configure.sh --restore  # Give the RAM back to the host
#
# --boost / --restore bracket a heavy run: raise the ceiling for the extraction,
# then hand the memory back. setup.sh does this automatically when the region is
# too large for the current allocation. Each change restarts Docker Desktop --
# the API accepts a new value but the engine only picks it up on restart.
#
# The chosen backend is written to .osrm-backend and read by setup.sh.
#
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_FILE="$SCRIPT_DIR/.osrm-backend"
DOCKER_SETTINGS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
OSRM_IMAGE="ghcr.io/project-osrm/osrm-backend:v26.9.0-arm64-debian"

BACKEND_SOCK="$HOME/Library/Containers/com.docker.docker/Data/backend.sock"
SAVED_RAM_FILE="$SCRIPT_DIR/.docker-ram-saved"

# Percentage of the host's physical RAM handed to the Docker VM when boosting.
# Capped by whatever ceiling Docker Desktop reports.
BOOST_PERCENT=100

# Memory left to the host, in MiB. 0 hands Docker the full ceiling.
# Note: the VM reserves its allocation from macOS, so leaving nothing pushes the
# host into swap; raise this if the machine becomes unresponsive or Docker fails
# to start after a boost.
HOST_RESERVE_MIB=0

# =============================================================================
# Inspection helpers
# =============================================================================
host_ram_mib() {
    echo $(( $(sysctl -n hw.memsize) / 1048576 ))
}

docker_ram_mib() {
    docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1/1048576}'
}

configured_ram_mib() {
    [ -f "$DOCKER_SETTINGS" ] || return 1
    python3 -c "
import json,sys
try: print(json.load(open('$DOCKER_SETTINGS')).get('MemoryMiB',''))
except Exception: sys.exit(1)
" 2>/dev/null
}

docker_running() {
    docker info > /dev/null 2>&1
}

# Docker Desktop publishes the ceiling it will accept; prefer it over guessing.
docker_max_ram_mib() {
    curl -s --unix-socket "$BACKEND_SOCK" http://localhost/app/settings 2>/dev/null \
        | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['vm']['resources']['memoryMiB']['max'])
except Exception: sys.exit(1)
" 2>/dev/null
}

docker_current_ram_mib() {
    curl -s --unix-socket "$BACKEND_SOCK" http://localhost/app/settings 2>/dev/null \
        | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['vm']['resources']['memoryMiB']['value'])
except Exception: sys.exit(1)
" 2>/dev/null
}

# How much to give the VM: a share of the host's physical RAM, minus
# HOST_RESERVE_MIB, and never above the ceiling Docker Desktop will accept.
boost_target_mib() {
    local host_mib max_mib target
    host_mib="$(host_ram_mib)"
    target=$(( host_mib * BOOST_PERCENT / 100 ))

    if [ "$HOST_RESERVE_MIB" -gt 0 ]; then
        target=$(( target - HOST_RESERVE_MIB ))
    fi

    # Docker Desktop may cap below the physical RAM; never exceed what it takes.
    max_mib="$(docker_max_ram_mib)" || max_mib=""
    if [ -n "$max_mib" ] && [ "$target" -gt "$max_mib" ]; then
        target="$max_mib"
    fi

    [ "$target" -lt 2048 ] && target=2048
    echo "$target"
}

# Write a memory value through the Docker Desktop API and restart the engine.
# The API persists the setting but the running VM keeps its old size, so the
# restart is what actually applies it.
apply_docker_ram() {
    local target="$1"

    if [ ! -S "$BACKEND_SOCK" ]; then
        echo -e "${RED}Docker Desktop backend socket not found.${NC}"
        echo -e "Set Memory manually in Docker Desktop > Settings > Resources."
        return 1
    fi

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"vm\":{\"resources\":{\"memoryMiB\":{\"value\":$target}}}}" \
        --unix-socket "$BACKEND_SOCK" http://localhost/app/settings 2>/dev/null)

    if [ "$code" != "200" ]; then
        echo -e "${RED}The API rejected the change (HTTP $code).${NC}"
        return 1
    fi

    echo "  Restarting Docker Desktop to apply..."
    docker desktop restart > /dev/null 2>&1 || {
        echo -e "${RED}Automatic restart failed. Restart Docker Desktop manually.${NC}"
        return 1
    }

    local i live
    for i in $(seq 1 90); do
        sleep 2
        if docker_running; then
            live="$(docker_ram_mib)"
            # The engine reports slightly less than the configured value.
            if [ "$live" -gt $(( target * 85 / 100 )) ]; then
                echo -e "${GREEN}-> Docker is back with ${live} MiB${NC}"
                return 0
            fi
        fi
    done

    echo -e "${YELLOW}Docker did not come back with the new size within 180s.${NC}"
    return 1
}

# Raise the VM for a heavy run, remembering what to restore later.
boost_docker_ram() {
    local current target
    current="$(docker_current_ram_mib)" || {
        echo -e "${RED}Could not read the current Docker memory setting.${NC}"
        return 1
    }
    target="$(boost_target_mib)"

    if [ "$current" -ge "$target" ]; then
        echo -e "${GREEN}Docker already has ${current} MiB, no boost needed.${NC}"
        return 0
    fi

    # Only record the baseline on the first boost, so repeated boosts do not
    # overwrite it with an already-boosted value.
    [ -f "$SAVED_RAM_FILE" ] || echo "$current" > "$SAVED_RAM_FILE"

    echo -e "Boosting Docker: ${YELLOW}${current}${NC} -> ${GREEN}${target}${NC} MiB"
    echo -e "  (${BOOST_PERCENT}% of $(host_ram_mib) MiB host RAM, Docker ceiling $(docker_max_ram_mib) MiB)"
    apply_docker_ram "$target"
}

# Hand the memory back to the host.
restore_docker_ram() {
    if [ ! -f "$SAVED_RAM_FILE" ]; then
        echo -e "${YELLOW}No saved value: nothing to restore.${NC}"
        return 0
    fi

    local saved current
    saved="$(tr -d '[:space:]' < "$SAVED_RAM_FILE")"
    current="$(docker_current_ram_mib)" || current=""

    if [ "$current" = "$saved" ]; then
        echo -e "${GREEN}Docker is already at ${saved} MiB.${NC}"
        rm -f "$SAVED_RAM_FILE"
        return 0
    fi

    echo -e "Restoring Docker: ${YELLOW}${current}${NC} -> ${GREEN}${saved}${NC} MiB"
    if apply_docker_ram "$saved"; then
        rm -f "$SAVED_RAM_FILE"
    else
        echo -e "${YELLOW}Restore failed; ${SAVED_RAM_FILE} kept for a retry.${NC}"
        return 1
    fi
}

native_available() {
    command -v osrm-extract > /dev/null 2>&1
}

# =============================================================================
# Status report
# =============================================================================
print_status() {
    echo -e "${CYAN}=== OSRM backend status ===${NC}\n"

    local host_mib
    host_mib="$(host_ram_mib)"
    echo -e "Host RAM: ${GREEN}$((host_mib / 1024)) GB${NC}"

    echo -ne "Docker  : "
    if docker_running; then
        local dram
        dram="$(docker_ram_mib)"
        echo -ne "${GREEN}running${NC}, ${dram} MiB allocated"
        local dmax
        dmax="$(docker_max_ram_mib)" || dmax=""
        [ -n "$dmax" ] && echo -ne " / ${dmax} MiB max"
        if [ "$dram" -lt 8192 ]; then
            echo -e " ${YELLOW}(too low for large regions)${NC}"
        else
            echo -e " ${GREEN}(sufficient)${NC}"
        fi
        if [ -f "$SAVED_RAM_FILE" ]; then
            echo -e "          ${YELLOW}boosted${NC}; ./configure.sh --restore returns it to $(cat "$SAVED_RAM_FILE") MiB"
        fi
    else
        echo -e "${YELLOW}not running${NC}"
    fi

    echo -ne "Native  : "
    if native_available; then
        echo -e "${GREEN}$(osrm-extract --version 2>/dev/null | head -1)${NC}"
    else
        echo -e "${YELLOW}not installed${NC}"
    fi

    echo -ne "Backend : "
    if [ -f "$BACKEND_FILE" ]; then
        echo -e "${GREEN}$(cat "$BACKEND_FILE")${NC} (from .osrm-backend)"
    else
        echo -e "${YELLOW}not configured, setup.sh defaults to docker${NC}"
    fi
    echo ""
}

# =============================================================================
# Native: install via Homebrew and extract the Lua profiles
# =============================================================================
setup_native() {
    if ! command -v brew > /dev/null 2>&1; then
        echo -e "${RED}Homebrew is required for the native backend.${NC}"
        echo -e "Install it from https://brew.sh, then re-run this script."
        return 1
    fi

    if native_available; then
        echo -e "${GREEN}osrm-extract already installed:${NC} $(command -v osrm-extract)"
    else
        echo -e "${YELLOW}Installing osrm-backend via Homebrew (a few minutes)...${NC}"
        echo -e "Dependencies: boost, libarchive, lua, tbb"
        read -p "Proceed? (y/n) " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || { echo "Cancelled."; return 1; }
        brew install osrm-backend
    fi

    # setup.sh needs car.lua. Homebrew ships the profiles, but the path varies;
    # keep a local copy so the location is stable.
    local profiles_dir="$SCRIPT_DIR/profiles"
    if [ ! -f "$profiles_dir/car.lua" ]; then
        echo "Locating the Lua profiles..."
        mkdir -p "$profiles_dir"
        local brew_profiles
        brew_profiles="$(brew --prefix osrm-backend 2>/dev/null)/share/osrm/profiles"
        if [ -f "$brew_profiles/car.lua" ]; then
            cp -R "$brew_profiles"/* "$profiles_dir/"
            echo -e "${GREEN}-> Profiles copied from $brew_profiles${NC}"
        elif docker_running; then
            echo "  Not found in Homebrew; extracting from the Docker image..."
            docker run --rm -v "$profiles_dir:/out" --entrypoint sh "$OSRM_IMAGE" \
                -c 'cp -R /opt/*.lua /opt/lib /out/ 2>/dev/null' || true
            [ -f "$profiles_dir/car.lua" ] && echo -e "${GREEN}-> Profiles extracted from the image${NC}"
        fi

        if [ ! -f "$profiles_dir/car.lua" ]; then
            echo -e "${RED}Could not locate car.lua.${NC}"
            echo -e "Download it from https://github.com/Project-OSRM/osrm-backend/tree/master/profiles"
            echo -e "into $profiles_dir/ and re-run."
            return 1
        fi
    else
        echo -e "${GREEN}Profiles already present:${NC} $profiles_dir"
    fi
    echo ""
}

# =============================================================================
# Persist the choice
# =============================================================================
write_backend() {
    echo "$1" > "$BACKEND_FILE"
    echo -e "${GREEN}=== Backend set to '$1' ===${NC}"
    echo -e "Written to ${YELLOW}.osrm-backend${NC}; setup.sh reads it automatically."
    echo -e "\nPrepare a region with: ${YELLOW}./setup.sh canada${NC}"
}

# =============================================================================
# Main
# =============================================================================
case "${1:-}" in
    --status)
        print_status
        exit 0
        ;;
    --docker)
        print_status
        write_backend docker
        exit 0
        ;;
    --boost)
        docker_running || { echo -e "${RED}Docker is not running.${NC}"; exit 1; }
        boost_docker_ram
        exit $?
        ;;
    --restore)
        docker_running || { echo -e "${RED}Docker is not running.${NC}"; exit 1; }
        restore_docker_ram
        exit $?
        ;;
    --native)
        print_status
        setup_native || exit 1
        write_backend native
        exit 0
        ;;
    "")
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        echo "Usage: ./configure.sh [--status|--docker|--native|--boost|--restore]"
        exit 1
        ;;
esac

# ---- Interactive ----
print_status

# Warn when Docker cannot handle a large region
if docker_running; then
    dram="$(docker_ram_mib)"
    if [ "$dram" -lt 8192 ]; then
        echo -e "${YELLOW}Warning: Docker has only ${dram} MiB.${NC}"
        echo -e "Extracting a large region (Canada, ~6 GB PBF) will be OOM-killed.\n"
    fi
fi

echo -e "${CYAN}Which backend should prepare the OSRM data?${NC}\n"
echo -e "  ${GREEN}1)${NC} Docker  - reproducible, no local install, profiles included"
echo -e "            needs enough RAM allocated to the Docker VM"
host_gb=$(( $(host_ram_mib) / 1024 ))
echo -e "  ${GREEN}2)${NC} Native  - uses all ${host_gb}GB of host RAM, faster (no VM)"
echo -e "            installs osrm-backend via Homebrew"
echo -e "  ${GREEN}3)${NC} Cancel\n"
echo -e "In both cases the servers themselves keep running under Docker;"
echo -e "only data preparation changes.\n"

read -p "Choice (1/2/3): " -n 1 -r choice
echo ""

case "$choice" in
    1)
        echo ""
        write_backend docker
        echo -e "\nsetup.sh boosts the RAM automatically when a region needs it,"
        echo -e "and hands it back afterwards. Manually: ${YELLOW}./configure.sh --boost${NC} / ${YELLOW}--restore${NC}"
        ;;
    2)
        echo ""
        setup_native || exit 1
        write_backend native
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac
