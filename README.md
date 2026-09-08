# OSRM Server

Multi-region [OSRM](http://project-osrm.org/) (Open Source Routing Machine) server, ready to use with Docker.

Compute routes, distance matrices, and find nearest points in milliseconds, all running locally.

---

Serveur [OSRM](http://project-osrm.org/) (Open Source Routing Machine) multi-regions, pret a l'emploi avec Docker.

Calculez des itineraires, des matrices de distances et trouvez les points les plus proches en quelques millisecondes, le tout en local.

## Features / Fonctionnalites

- **Multi-region**: Canada, Quebec, USA, Netherlands, Australia, Italy or any Geofabrik region
- **Docker**: No local installation required, everything runs in containers
- **Automated scripts**: configure, setup, start, stop, status in one command
- **Parallel downloads**: OSM extracts fetched over several connections (curl only)
- **Custom regions**: Add any region with a Geofabrik URL
- **REST API**: Standard OSRM endpoints (route, table, nearest, trip, match)

## Prerequisites / Prerequis

- [Docker](https://docs.docker.com/get-docker/) (with Docker Compose) -- runs the servers
- `curl`
- [Homebrew](https://brew.sh) -- optional, only for the native processing backend

## Quick Start / Demarrage rapide

```bash
# 1. Clone the project / Cloner le projet
git clone https://github.com/Pierre-AdrienLefevre/osrm-server.git
cd osrm-server

# 2. Pick a processing backend / Choisir le backend de traitement
./configure.sh

# 3. Download and prepare data (15-30 min) / Telecharger et preparer les donnees
./setup.sh canada

# 4. Start the server / Demarrer le serveur
./start.sh canada
```

The server is available at `http://localhost:5001`.

## Processing Backend / Backend de traitement

Data preparation (`osrm-extract`) is memory hungry: it needs roughly **twice the
PBF size** in RAM. Canada (~6 GB PBF) therefore needs ~12 GB, well above the few
GB Docker Desktop allocates by default -- the container is OOM-killed mid-run.

`./configure.sh` inspects the machine and picks a backend:

```bash
./configure.sh            # Interactive
./configure.sh --status   # Report only, changes nothing
./configure.sh --docker   # Prepare data in Docker
./configure.sh --native   # Prepare data with native binaries (Homebrew)
```

| Backend | Pros | Cons |
|---------|------|------|
| **Docker** (default) | Reproducible, nothing to install, Lua profiles included | Limited to the VM's RAM; large regions need a boost + 2 Docker restarts |
| **Native** | Uses host RAM directly, faster (no VM), no restarts | Needs Homebrew (`osrm-backend` + boost, libarchive, lua, tbb) |

**Either way the servers still run under Docker** -- only data preparation
changes. The choice lives in `.osrm-backend`; override it per run with
`OSRM_BACKEND=native ./setup.sh <region>`.

### Which one? / Lequel choisir ?

**Native** is the better default on a personal machine: no restarts, no RAM
permanently reserved, and the extraction runs outside a VM.

**Docker** is worth the boost dance when the setup must be reproducible on
someone else's machine or in CI, where nothing can be installed locally.

### RAM boost (Docker backend only)

When a region needs more RAM than the Docker VM has, `setup.sh` borrows host
memory for the extraction and gives it back afterwards:

```bash
./configure.sh --boost     # raise the VM to BOOST_PERCENT of host RAM
./configure.sh --restore   # give the memory back
```

This is automatic -- `setup.sh` compares the PBF size against the current
allocation and only boosts when needed, so small regions never trigger a
restart. The previous value is saved in `.docker-ram-saved` and restored even if
the run is interrupted (Ctrl-C included).

Two constants at the top of `configure.sh` control the sizing:

| Constant | Default | Meaning |
|----------|---------|---------|
| `BOOST_PERCENT` | `100` | Share of the host's physical RAM given to the VM |
| `HOST_RESERVE_MIB` | `0` | MiB held back for the host |

The target is capped by the ceiling Docker Desktop reports, so it never asks for
more than Docker accepts.

> **Note:** Docker Desktop only applies a memory change on restart, so each
> boost/restore cycle restarts Docker and interrupts running servers. Raise
> `HOST_RESERVE_MIB` if the machine becomes unresponsive during extraction or if
> Docker fails to start after a boost.

## Routing Algorithm / Algorithme de routage

OSRM indexes the road graph with one of two algorithms. `setup.sh` prepares CH by
default; pass `mld` as the second argument for the other one.

```bash
./setup.sh canada        # CH  -> regions/canada/ch/
./setup.sh canada mld    # MLD -> regions/canada/mld/
```

| | CH (Contraction Hierarchies) | MLD (Multi-Level Dijkstra) |
|---|---|---|
| Queries | Faster | Slightly slower |
| Preparation | Slower (`osrm-contract`) | Faster (`osrm-partition` + `osrm-customize`) |
| Traffic updates | Full re-contraction | Cheap re-customization |

The two share the `.pbf` but no generated file, so each gets its own directory and
its own extraction. Switching a service to MLD means mounting `.../mld` and passing
`--algorithm mld` in `docker-compose.yml`.

> **Note:** OSRM datasets are not portable across platforms. Data prepared with the
> native backend on macOS is rejected by the Linux containers -- prepare and serve
> with the same backend.

## Pre-configured Regions / Regions pre-configurees

| Region | Command | Port | Source |
|--------|---------|------|--------|
| Canada | `./setup.sh canada` | 5001 | [Geofabrik](https://download.geofabrik.de/north-america/canada-latest.osm.pbf) |
| Quebec | `./setup.sh quebec` | 5002 | [Geofabrik](https://download.geofabrik.de/north-america/canada/quebec-latest.osm.pbf) |
| USA | `./setup.sh usa` | 5003 | [Geofabrik](https://download.geofabrik.de/north-america/us-latest.osm.pbf) |
| Netherlands | `./setup.sh netherlands` | 5004 | [Geofabrik](https://download.geofabrik.de/europe/netherlands-latest.osm.pbf) |
| Australia | `./setup.sh australia` | 5005 | [Geofabrik](https://download.geofabrik.de/australia-oceania/australia-latest.osm.pbf) |
| Italy | `./setup.sh italy` | 5006 | [Geofabrik](https://download.geofabrik.de/europe/italy-latest.osm.pbf) |

### Add a custom region / Ajouter une region custom

Find your region on [download.geofabrik.de](https://download.geofabrik.de/) and run:

```bash
./setup.sh my-region https://download.geofabrik.de/europe/france-latest.osm.pbf
```

Then add the corresponding service in `docker-compose.yml`.

## API Examples / Exemples d'API

### Route (calculate a route / calculer un itineraire)

```bash
# Montreal -> Quebec City
curl "http://localhost:5001/route/v1/driving/-73.5673,45.5017;-71.2080,46.8139?overview=full&geometries=geojson"
```

### Table (distance matrix / matrice de distances)

```bash
curl "http://localhost:5001/table/v1/driving/-73.5673,45.5017;-71.2080,46.8139;-75.6972,45.4215"
```

### Nearest (closest point on road network / point le plus proche)

```bash
curl "http://localhost:5001/nearest/v1/driving/-73.5673,45.5017?number=3"
```

### Trip (route optimization / optimisation de tournee - TSP)

```bash
curl "http://localhost:5001/trip/v1/driving/-73.5673,45.5017;-71.2080,46.8139;-75.6972,45.4215?roundtrip=true"
```

### Match (map matching / GPS -> route)

```bash
curl "http://localhost:5001/match/v1/driving/-73.5673,45.5017;-73.5600,45.5050;-73.5534,45.5088?timestamps=0;1;2"
```

> See `examples/curl-examples.sh` for more detailed examples.

## Downloads / Telechargements

`setup.sh` fetches OSM extracts over several parallel HTTP range requests, since
Geofabrik throttles per connection. Roughly 2x faster on large files, with plain
`curl` -- nothing to install.

```bash
DOWNLOAD_CONNECTIONS=12 ./setup.sh canada   # default: 6
```

It falls back to a single connection when the server does not advertise
`Accept-Ranges`, when the file is under 10 MB, or when any range fails. The
reassembled file is checked against the announced `Content-Length`.

## Available Scripts / Scripts disponibles

| Script | Description |
|--------|-------------|
| `./configure.sh` | Choose the processing backend (Docker or native) |
| `./setup.sh <region>` | Download and prepare OSRM data for a region (CH) |
| `./setup.sh <region> mld` | Same, using the MLD algorithm |
| `./setup.sh --clean <region>` | Remove generated data, keep the `.pbf` |
| `./setup.sh --purge <region>` | Remove everything, `.pbf` included |
| `./start.sh [region]` | Start servers (all or a specific one) |
| `./stop.sh` | Stop all servers |
| `./status.sh` | Display server status and test connectivity |

## Useful Docker Commands / Commandes Docker utiles

```bash
# View logs in real time / Voir les logs en temps reel
docker compose logs -f

# View container status / Voir le statut des containers
docker compose ps

# Restart a service / Redemarrer un service
docker compose restart osrm-canada
```

## Project Structure / Structure du projet

```
osrm-server/
├── docker-compose.yml    # OSRM service configuration
├── configure.sh          # Backend selection (Docker / native)
├── setup.sh              # Data download and preparation
├── start.sh              # Start servers
├── stop.sh               # Stop servers
├── status.sh             # Status and connectivity test
├── examples/
│   └── curl-examples.sh  # API request examples
├── regions/              # OSRM data (not versioned, generated by setup.sh)
│   ├── canada/
│   │   ├── canada-latest.osm.pbf   # shared source
│   │   ├── ch/                     # data for the CH algorithm
│   │   └── mld/                    # data for MLD, if prepared
│   ├── netherlands/
│   ├── italy/
│   └── ...
├── .osrm-backend         # Selected backend (not versioned)
├── LICENSE
└── README.md
```

## License

MIT - see [LICENSE](LICENSE)
