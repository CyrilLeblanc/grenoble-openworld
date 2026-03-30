"""
Central configuration for the Grenoble Openworld data pipeline.
All parameters live here — no magic numbers in individual scripts.
"""

from dataclasses import dataclass
from pathlib import Path
import math


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

ROOT_DIR = Path(__file__).parent
OUTPUT_DIR = ROOT_DIR / "output"

OSM_SOURCE_PBF = OUTPUT_DIR / "rhone-alpes-latest.osm.pbf"
OSM_CLIPPED_PBF = OUTPUT_DIR / "grenoble.osm.pbf"
BUILDINGS_GEOJSON = OUTPUT_DIR / "buildings.geojson"
LANDUSE_GEOJSON   = OUTPUT_DIR / "landuse.geojson"
ROADS_GEOJSON     = OUTPUT_DIR / "roads.geojson"

DEM_RAW_DIR = OUTPUT_DIR / "dem_tiles"
HEIGHTMAP_PNG = OUTPUT_DIR / "heightmap.png"

OSM_TILE_CACHE_DIR  = OUTPUT_DIR / "osm_tiles"
TERRAIN_TEXTURE_PNG = OUTPUT_DIR / "terrain_texture.png"

GODOT_DATA_DIR = ROOT_DIR.parent / "data"


# ---------------------------------------------------------------------------
# World parameters
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class WorldConfig:
    center_lat: float
    center_lon: float
    radius_m: float          # radius around center to include
    heightmap_size: int      # output PNG resolution (square)
    tile_zoom: int           # OSM tile zoom level for terrain texture
    terrain_texture_size: int  # terrain texture output resolution (square)

    def bbox(self) -> tuple[float, float, float, float]:
        """Return (min_lon, min_lat, max_lon, max_lat) for the given radius."""
        # Approximate degrees per metre at this latitude
        lat_deg_per_m = 1.0 / 111_320.0
        lon_deg_per_m = 1.0 / (111_320.0 * math.cos(math.radians(self.center_lat)))

        delta_lat = self.radius_m * lat_deg_per_m
        delta_lon = self.radius_m * lon_deg_per_m

        return (
            self.center_lon - delta_lon,  # min_lon (west)
            self.center_lat - delta_lat,  # min_lat (south)
            self.center_lon + delta_lon,  # max_lon (east)
            self.center_lat + delta_lat,  # max_lat (north)
        )


# ---------------------------------------------------------------------------
# OSM way exclusions
# ---------------------------------------------------------------------------

# Way IDs to skip during building extraction.
# Use this to suppress large outline ways that hide finer building:part detail.
# Find IDs on openstreetmap.org → click a way → note the number in the URL.
EXCLUDED_WAY_IDS: set[int] = {
    # Add way IDs here only for cases the spatial detection cannot handle
    # (e.g. a building outline that has no parts inside it but is still wrong).
    # Example: 28696571 was here but is now correctly caught by spatial detection.
}


# Default world — 10 km radius around Grenoble city centre
WORLD = WorldConfig(
    center_lat=45.188967,
    center_lon=5.724615,
    radius_m=5_000,            # 5 000 m → 10 km diameter
    heightmap_size=1024,
    tile_zoom=15,              # zoom 15 ≈ 3.4 m/px at this latitude (~30 tiles per axis)
    terrain_texture_size=4096, # final texture resolution after stitching and cropping
)
