# Grenoble Openworld

A 3D open-world recreation of Grenoble built from real geospatial data — OpenStreetMap + Copernicus DEM — running in Godot 4.6.

Walk through the streets, fly over the mountains, and explore a procedurally generated city with real building footprints, roads, forests, and terrain.

---

## Features

- **Terrain** — 1024×1024 heightmap from Copernicus DEM (30 m resolution, Gaussian-smoothed), covering a 10 km × 10 km area around Grenoble city centre
- **Buildings** — ~10 000 extruded footprints from OSM with correct heights (`building:levels`, `height` tags), procedural facade shader with windows and doors per building type
- **Roads** — Ribbon meshes for all highway classes (motorway → service) and waterways, coloured by category
- **Landuse** — Splat texture baked from OSM polygons (forests, parks, farmland, water, etc.) applied directly to the terrain
- **Trees** — MultiMesh with ~55 000 individual OSM tree positions + scattered forest instances; single draw call
- **Player** — Walking mode (gravity, jump) and free-fly noclip, toggled with F4

---

## Tech stack

| Layer | Technology |
|---|---|
| Game engine | Godot 4.6 — GL Compatibility renderer, Jolt Physics |
| Game logic | GDScript |
| Facade rendering | Custom spatial shader (`shaders/facade.gdshader`) |
| Data pipeline | Python 3.12 in isolated venv |
| OSM parsing | osmium 4.3.0 |
| Geodata | rasterio, pyproj, shapely |
| Image processing | Pillow, numpy |

---

## Data sources

| Source | Content |
|---|---|
| OpenStreetMap (Geofabrik Rhône-Alpes) | Buildings, roads, landuse, trees |
| Copernicus DEM GLO-30 | Terrain elevation (30 m/px) |

---

## Project structure

```
grenoble-openworld/
├── autoloads/
│   ├── WorldConfig.gd        # World dimensions + elevation metadata (singleton)
│   └── WorldEvents.gd        # Signal bus for decoupled communication
├── data/                     # Generated assets (not committed)
│   ├── heightmap.png
│   ├── heightmap.json
│   ├── buildings.geojson
│   ├── landuse.geojson
│   ├── landuse_texture.png
│   ├── roads.geojson
│   └── trees.geojson
├── scenes/
│   └── main.tscn
├── scripts/
│   ├── Terrain.gd            # Heightmap → mesh + landuse texture
│   ├── BuildingSpawner.gd    # Reads buildings.geojson, instantiates meshes
│   ├── BuildingMeshFactory.gd # Extruded polygon mesh with UV mapping
│   ├── BuildingMaterialLibrary.gd # OSM tag → shader/material per building type
│   ├── RoadMeshSpawner.gd    # Road + waterway ribbon meshes
│   ├── ForestSpawner.gd      # MultiMesh tree scatter (forest polygons + OSM nodes)
│   ├── ChunkManager.gd       # Chunk loading infrastructure (streaming — Phase 3)
│   └── NoclipPlayer.gd       # Walking mode + noclip camera
├── shaders/
│   └── facade.gdshader       # Procedural windows + doors on building walls
└── tools/
    ├── config.py             # Pipeline configuration (center, radius, paths)
    ├── setup.sh              # Create venv + install dependencies
    ├── download_osm.py       # Download Rhône-Alpes PBF, clip to bbox
    ├── download_dem.py       # Download Copernicus DEM tiles
    ├── process_dem.py        # DEM → heightmap PNG + JSON metadata
    ├── extract_buildings.py  # OSM PBF → buildings.geojson
    ├── extract_landuse.py    # OSM PBF → landuse.geojson
    ├── extract_roads.py      # OSM PBF → roads.geojson
    ├── extract_trees.py      # OSM PBF → trees.geojson
    ├── generate_landuse_texture.py  # Rasterise landuse polygons → PNG
    ├── download_terrain_texture.py  # (unused) OSM tile satellite texture
    └── export_to_godot.py    # Copy all pipeline outputs to data/
```

---

## Setup

### Prerequisites

- Godot 4.6+
- Python 3.12+

### 1 — Data pipeline

```bash
cd tools
bash setup.sh
source venv/bin/activate

# Downloads (~500 MB OSM PBF + DEM tiles, takes 20–40 min)
python download_osm.py
python download_dem.py

# Processing (5–10 min)
python process_dem.py
python extract_buildings.py
python extract_landuse.py
python extract_roads.py
python extract_trees.py
python generate_landuse_texture.py

# Copy outputs to data/
python export_to_godot.py
```

### 2 — Run

Open `project.godot` in Godot 4.6 and press **Play**.

---

## Controls

| Key | Action |
|---|---|
| WASD | Move |
| Mouse | Look |
| Shift | Sprint |
| Space | Jump (walk mode) |
| F4 | Toggle noclip / walk |
| Escape | Release mouse |
| Scroll wheel | Adjust noclip speed |

---

## Coordinate system

All pipeline scripts and Godot scripts share the same convention:

| Space | Convention |
|---|---|
| Source data | WGS84 (lat/lon) |
| Pipeline + GeoJSON | Local UTM 31N metres, origin = world centre |
| Godot | X = east, Y = up, Z = south (northing flipped) |

---

## Roadmap

| Phase | Status | Content |
|---|---|---|
| 1 | ✅ | Terrain + grey buildings + noclip camera |
| 2 | ✅ | OSM textures, roads, landuse splat, walking mode |
| 3 | 🔄 | Procedural facades, MultiMesh trees, LOD |
| 4 | ⬜ | Landmark models, streaming chunks, water shader |
