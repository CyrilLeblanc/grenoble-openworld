"""
extract_landuse.py — Extract landuse / natural / leisure areas from the clipped OSM PBF.

Tags extracted:
  natural : wood, water, grassland, scrub, heath, wetland
  landuse : forest, grass, meadow, farmland, orchard, vineyard, allotments,
            park, recreation_ground, residential, industrial, commercial, retail
  leisure : park, garden, pitch, golf_course

Each feature gets a normalised "type" property used by Godot for material mapping:
  wood, water, grass, wetland, farmland, park, sports, residential, industrial

Coordinates are projected to local metres (UTM 31N, origin = world centre),
matching buildings.geojson and heightmap.json.

Usage:
    python extract_landuse.py

Output:
    output/landuse.geojson
"""

import json
import sys

import osmium
import osmium.geom
from pyproj import Transformer
from shapely.geometry import mapping, Polygon
from shapely.wkb import loads as wkb_loads

from config import WORLD, OSM_CLIPPED_PBF, LANDUSE_GEOJSON


# ---------------------------------------------------------------------------
# Coordinate projection
# ---------------------------------------------------------------------------

_wgs84_to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
_cx, _cy = _wgs84_to_utm.transform(WORLD.center_lon, WORLD.center_lat)


def _project(lon: float, lat: float) -> tuple[float, float]:
    x, y = _wgs84_to_utm.transform(lon, lat)
    return x - _cx, y - _cy


# ---------------------------------------------------------------------------
# Tag → normalised type
# ---------------------------------------------------------------------------

_NATURAL_TYPE: dict[str, str] = {
    "wood":      "wood",
    "forest":    "wood",
    "water":     "water",
    "grassland": "grass",
    "heath":     "grass",
    "scrub":     "grass",
    "wetland":   "wetland",
}

_LANDUSE_TYPE: dict[str, str] = {
    "forest":           "wood",
    "grass":            "grass",
    "meadow":           "grass",
    "greenfield":       "grass",
    "recreation_ground":"grass",
    "farmland":         "farmland",
    "orchard":          "farmland",
    "vineyard":         "farmland",
    "allotments":       "farmland",
    "park":             "park",
    "village_green":    "park",
    "residential":      "residential",
    "industrial":       "industrial",
    "commercial":       "industrial",
    "retail":           "industrial",
}

_LEISURE_TYPE: dict[str, str] = {
    "park":         "park",
    "garden":       "park",
    "pitch":        "sports",
    "golf_course":  "sports",
    "sports_centre":"sports",
}

_WATERWAY_TYPE: dict[str, str] = {
    "riverbank": "water",
    "dock":      "water",
    "basin":     "water",
    "canal":     "water",
}


def _resolve_type(tags: osmium.osm.TagList) -> str | None:
    t = _NATURAL_TYPE.get(tags.get("natural", ""))
    if t:
        return t
    t = _WATERWAY_TYPE.get(tags.get("waterway", ""))
    if t:
        return t
    t = _LANDUSE_TYPE.get(tags.get("landuse", ""))
    if t:
        return t
    t = _LEISURE_TYPE.get(tags.get("leisure", ""))
    if t:
        return t
    return None


# ---------------------------------------------------------------------------
# OSM handler
# ---------------------------------------------------------------------------

class _LanduseHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.features: list[dict] = []
        self._wkb_factory = osmium.geom.WKBFactory()

    def area(self, area: osmium.osm.Area) -> None:
        tags = area.tags
        landuse_type = _resolve_type(tags)
        if landuse_type is None:
            return

        try:
            wkb = self._wkb_factory.create_multipolygon(area)
        except Exception:
            return

        geom = wkb_loads(wkb, hex=True)

        def project_ring(coords):
            return [_project(lon, lat) for lon, lat in coords]

        for polygon in (geom.geoms if geom.geom_type == "MultiPolygon" else [geom]):
            exterior = project_ring(polygon.exterior.coords)
            if len(exterior) < 3:
                continue
            projected = Polygon(exterior)
            if not projected.is_valid or projected.area < 1.0:
                continue

            self.features.append({
                "type": "Feature",
                "geometry": mapping(projected),
                "properties": {
                    "type":    landuse_type,
                    "natural": tags.get("natural"),
                    "landuse": tags.get("landuse"),
                    "leisure": tags.get("leisure"),
                    "name":    tags.get("name"),
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

    print("Extracting landuse / natural / leisure areas ...")
    handler = _LanduseHandler()
    handler.apply_file(str(OSM_CLIPPED_PBF), locations=True, idx="flex_mem")
    print(f"  Extracted {len(handler.features)} features.")

    from collections import Counter
    type_counts = Counter(f["properties"]["type"] for f in handler.features)
    for t, c in sorted(type_counts.items(), key=lambda x: -x[1]):
        print(f"    {t}: {c}")

    geojson = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "local_metres_utm31n"}},
        "features": handler.features,
    }

    LANDUSE_GEOJSON.parent.mkdir(parents=True, exist_ok=True)
    with open(LANDUSE_GEOJSON, "w", encoding="utf-8") as f:
        json.dump(geojson, f, separators=(",", ":"))

    print(f"Saved → {LANDUSE_GEOJSON}")


if __name__ == "__main__":
    main()
