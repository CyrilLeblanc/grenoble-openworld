"""
extract_trees.py — Extract individual tree nodes (natural=tree) from the clipped OSM PBF.

Each feature is a GeoJSON Point with properties:
  species        : OSM species or species:en tag (may be null)
  genus          : OSM genus tag, or first word of species if absent (may be null)
  height         : parsed height in metres (may be null)
  circumference  : trunk circumference in metres (may be null)
  diameter_crown : canopy diameter in metres (may be null)
  start_date     : planting year string e.g. "1985" (may be null)

Coordinates are projected to local metres (UTM 31N, origin = world centre),
matching buildings.geojson and heightmap.json.

Usage:
    python extract_trees.py

Output:
    output/trees.geojson
"""

import json
import sys

import osmium
from pyproj import Transformer

from config import WORLD, OSM_CLIPPED_PBF, TREES_GEOJSON


# ---------------------------------------------------------------------------
# Coordinate projection
# ---------------------------------------------------------------------------

_wgs84_to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
_cx, _cy = _wgs84_to_utm.transform(WORLD.center_lon, WORLD.center_lat)


def _project(lon: float, lat: float) -> tuple[float, float]:
    x, y = _wgs84_to_utm.transform(lon, lat)
    return x - _cx, y - _cy


def _parse_height(raw: str | None) -> float | None:
    if raw is None:
        return None
    try:
        return float(raw.split()[0])
    except (ValueError, IndexError):
        return None


# ---------------------------------------------------------------------------
# OSM handler
# ---------------------------------------------------------------------------

class _TreeHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.features: list[dict] = []

    def node(self, n: osmium.osm.Node) -> None:
        if n.tags.get("natural") != "tree":
            return
        if not n.location.valid():
            return

        x, y = _project(n.location.lon, n.location.lat)

        species = n.tags.get("species:en") or n.tags.get("species")
        height  = _parse_height(n.tags.get("height"))

        # Genus: explicit tag, or infer from first word of species name.
        genus_raw = n.tags.get("genus")
        if not genus_raw and species:
            genus_raw = species.split()[0]
        genus = genus_raw.capitalize() if genus_raw else None

        circumference  = _parse_height(n.tags.get("circumference"))
        diameter_crown = _parse_height(n.tags.get("diameter_crown"))
        start_date     = n.tags.get("start_date")  # "1985", "1985-06-01", …

        self.features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [x, y]},
            "properties": {
                "species":        species,
                "genus":          genus,
                "height":         height,
                "circumference":  circumference,
                "diameter_crown": diameter_crown,
                "start_date":     start_date,
            },
        })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    if not OSM_CLIPPED_PBF.exists():
        print(
            f"Clipped PBF not found: {OSM_CLIPPED_PBF}\n"
            "Run download_osm.py first.",
            file=sys.stderr,
        )
        sys.exit(1)

    print("Extracting individual trees (natural=tree) ...")
    handler = _TreeHandler()
    handler.apply_file(str(OSM_CLIPPED_PBF))
    print(f"  Extracted {len(handler.features)} trees.")

    with_species = sum(1 for f in handler.features if f["properties"]["species"])
    with_height  = sum(1 for f in handler.features if f["properties"]["height"])
    print(f"  With species: {with_species}  |  With height: {with_height}")

    geojson = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "local_metres_utm31n"}},
        "features": handler.features,
    }

    TREES_GEOJSON.parent.mkdir(parents=True, exist_ok=True)
    with open(TREES_GEOJSON, "w", encoding="utf-8") as f:
        json.dump(geojson, f, separators=(",", ":"))

    print(f"Saved → {TREES_GEOJSON}")


if __name__ == "__main__":
    main()
