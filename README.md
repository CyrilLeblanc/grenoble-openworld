# Grenoble Openworld

A 3D open-world recreation of Grenoble built from real geospatial data — OpenStreetMap + IGN RGE ALTI — running in Godot 4.6.

Walk through the streets, fly over the mountains, and explore a procedurally generated city with real building footprints, roads, forests, and terrain.

---

## Features

- **Terrain** — 1024×1024 heightmap from IGN RGE ALTI® DTM (1 m resolution, adaptive smoothing), covering a 10 km × 10 km area around Grenoble city centre
- **Buildings** — ~10 000 extruded footprints from OSM with correct heights; facade atlas shader with 8 material slots (haussmannien, béton 70s, moderne, industriel…), procedural windows and doors
- **Roads** — PBR asphalt shader with French IISR markings (edge lines + T1 centre dashes); cross-section profile with 15 cm curbs; LOD ribbon at distance; bridge deck height interpolation with 1 m railings
- **Sidewalks** — offset ribbon meshes at +15 cm (curb height), procedural concrete paving slab shader; presence inferred from OSM `sidewalk` tag or road category
- **Water** — animated procedural water shader (dual-scrolling sine-wave normals in world space, blue-green tint, high specular) for rivers, canals, and lakes
- **Landuse** — terrain overlay polygons (forest, park, farmland, sports, wetland, industrial) from OSM
- **Trees** — 3 mesh silhouettes (generic deciduous, conifer, broad-crown); non-uniform scale from OSM `height` + `diameter_crown`; age factor from `start_date`; forest polygon scatter + individual OSM nodes; MultiMesh LOD (3D mesh < 600 m → billboard < 1400 m)
- **Street furniture** — MultiMesh spawner for OSM-tagged street lamps, benches, bins, bus stops, and bike racks; LOD 300 m; orientation from OSM `direction` tag
- **Player** — Walking mode (gravity, jump) and free-fly noclip, toggled with F4

---

## Tech stack

| Layer | Technology |
|---|---|
| Game engine | Godot 4.6 — GL Compatibility renderer, Jolt Physics |
| Game logic | GDScript |
| Rendering | Custom spatial shaders: `facade`, `road`, `sidewalk`, `water` |
| Data pipeline | Python 3.12 in isolated venv |
| OSM parsing | osmium 4.3.0 |
| Geodata | rasterio, pyproj, shapely |
| Image processing | Pillow, numpy |

---

## Data sources

| Source | Content |
|---|---|
| OpenStreetMap (Geofabrik Rhône-Alpes) | Buildings, roads, landuse, trees, street furniture |
| IGN RGE ALTI® 1 m (WMTS) | Terrain elevation — true DTM (buildings excluded) |

---

## Project structure

```
grenoble-openworld/
├── autoloads/
│   ├── WorldConfig.gd        # World dimensions, LOD distances, elevation metadata
│   └── WorldEvents.gd        # Signal bus for decoupled spawner communication
├── data/                     # Generated assets (not committed — run pipeline first)
│   ├── heightmap.png / .json
│   ├── buildings.geojson
│   ├── landuse.geojson
│   ├── landuse_texture.png
│   ├── roads.geojson
│   ├── trees.geojson
│   ├── furniture.geojson
│   └── facade_atlas.png
├── scenes/
│   └── main.tscn
├── scripts/
│   ├── Terrain.gd               # Heightmap → mesh + landuse texture overlay
│   ├── BuildingSpawner.gd       # Reads buildings.geojson, instantiates meshes
│   ├── BuildingMeshFactory.gd   # Extruded polygon mesh with UV mapping
│   ├── BuildingMaterialLibrary.gd # OSM tag → facade shader slot per building
│   ├── RoadMeshSpawner.gd       # Road cross-section profile + waterway ribbons + bridges
│   ├── SidewalkSpawner.gd       # Sidewalk offset ribbons with paving slab shader
│   ├── LanduseMeshSpawner.gd    # Landuse polygon overlays (water uses animated shader)
│   ├── ForestSpawner.gd         # 3-type MultiMesh tree scatter (forest + OSM nodes)
│   ├── FurnitureSpawner.gd      # Street furniture MultiMesh (lamp, bench, bin, …)
│   ├── ChunkManager.gd          # Chunk loading infrastructure (streaming-ready)
│   └── NoclipPlayer.gd          # Walking mode + noclip camera
├── shaders/
│   ├── facade.gdshader          # Procedural windows + doors, 8-slot atlas
│   ├── road.gdshader            # PBR asphalt + French IISR markings
│   ├── sidewalk.gdshader        # Concrete paving slab grid
│   └── water.gdshader           # Animated wave normals, specular reflections
└── tools/
    ├── config.py                # Pipeline config (centre, radius, all output paths)
    ├── setup.sh                 # Create venv + install dependencies
    ├── download_osm.py          # Download Rhône-Alpes PBF, clip to bbox
    ├── download_dem_ign.py      # Download IGN RGE ALTI tiles via WMTS
    ├── process_dem.py           # DEM → heightmap PNG + JSON (adaptive smoothing)
    ├── extract_buildings.py     # OSM PBF → buildings.geojson
    ├── extract_landuse.py       # OSM PBF → landuse.geojson
    ├── extract_roads.py         # OSM PBF → roads.geojson (incl. bridge, sidewalk, lanes)
    ├── extract_trees.py         # OSM PBF → trees.geojson (incl. genus, crown, age)
    ├── extract_furniture.py     # OSM PBF → furniture.geojson (lamp, bench, bin, …)
    ├── generate_facade_atlas.py # Build 8-slot facade texture atlas (CC0 sources)
    ├── generate_landuse_texture.py # Rasterise landuse polygons → PNG overlay
    └── export_to_godot.py       # Copy all pipeline outputs to data/
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

# Downloads (~500 MB OSM PBF + IGN DEM tiles, takes 20–40 min)
python download_osm.py
python download_dem_ign.py

# Terrain processing
python process_dem.py

# OSM extraction
python extract_buildings.py
python extract_landuse.py
python extract_roads.py
python extract_trees.py
python extract_furniture.py

# Asset generation
python generate_facade_atlas.py
python generate_landuse_texture.py

# Copy everything to data/
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
| 1 | ✅ | LOD infrastructure, ChunkManager, per-system LOD distances |
| 2 | ✅ | IGN RGE ALTI terrain, facade atlas with 8 material slots |
| 3 | ✅ | PBR road shader (IISR markings), curb cross-section, sidewalks |
| 4 | ✅ | Animated water shader, bridge deck interpolation + railings |
| 5 | ✅ | 3-type tree silhouettes, non-uniform scale, street furniture |
| 6 | ⬜ | HDR sky, atmospheric haze |
| 7 | ⬜ | Day/night cycle |
