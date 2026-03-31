"""
extract_roads.py — Extract road and waterway lines from the clipped OSM PBF.

highway= values extracted (with default width in metres):
  motorway / motorway_link   → 12 / 8 m
  trunk    / trunk_link      → 10 / 7 m
  primary  / primary_link    →  8 / 6 m
  secondary/ secondary_link  →  6 / 5 m
  tertiary / tertiary_link   →  5 / 4 m
  unclassified / residential →  4 m
  service                    →  3 m

waterway= values extracted:
  river   → 20 m
  canal   →  8 m
  stream  →  4 m

Each feature gets:
  category : road category string (motorway, primary, local, service, river, …)
  width    : ribbon width in metres (float)
  name     : OSM name tag (may be null)

Coordinates are projected to local metres (UTM 31N, origin = world centre).

Usage:
    python extract_roads.py

Output:
    output/roads.geojson
"""

import json
import sys

import osmium
from pyproj import Transformer

from config import WORLD, OSM_CLIPPED_PBF, ROADS_GEOJSON


# ---------------------------------------------------------------------------
# Coordinate projection
# ---------------------------------------------------------------------------

_wgs84_to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
_cx, _cy = _wgs84_to_utm.transform(WORLD.center_lon, WORLD.center_lat)


def _project(lon: float, lat: float) -> tuple[float, float]:
    x, y = _wgs84_to_utm.transform(lon, lat)
    return x - _cx, y - _cy


# ---------------------------------------------------------------------------
# Tag → (category, width)
# ---------------------------------------------------------------------------

_HIGHWAY: dict[str, tuple[str, float]] = {
    "motorway":        ("motorway",  12.0),
    "motorway_link":   ("motorway",   8.0),
    "trunk":           ("trunk",     10.0),
    "trunk_link":      ("trunk",      7.0),
    "primary":         ("primary",    8.0),
    "primary_link":    ("primary",    6.0),
    "secondary":       ("secondary",  6.0),
    "secondary_link":  ("secondary",  5.0),
    "tertiary":        ("tertiary",   5.0),
    "tertiary_link":   ("tertiary",   4.0),
    "unclassified":    ("local",      4.0),
    "residential":     ("local",      4.0),
    "service":         ("service",    3.0),
}

# Default lane counts per highway type (used when lanes= tag is absent).
_DEFAULT_LANES: dict[str, int] = {
    "motorway": 3, "motorway_link": 1,
    "trunk": 2,    "trunk_link": 1,
    "primary": 2,  "primary_link": 1,
    "secondary": 2, "secondary_link": 1,
    "tertiary": 2, "tertiary_link": 1,
    "unclassified": 1,
    "residential": 1,
    "service": 1,
}

_WATERWAY: dict[str, tuple[str, float]] = {
    "river":  ("river",   20.0),
    "canal":  ("canal",    8.0),
    "stream": ("stream",   4.0),
}


def _resolve(tags: osmium.osm.TagList) -> tuple[str, float] | tuple[None, None]:
    hw = tags.get("highway")
    if hw and hw in _HIGHWAY:
        return _HIGHWAY[hw]
    ww = tags.get("waterway")
    if ww and ww in _WATERWAY:
        return _WATERWAY[ww]
    return None, None


# ---------------------------------------------------------------------------
# OSM handler
# ---------------------------------------------------------------------------

class _RoadHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.features: list[dict] = []

    def way(self, w: osmium.osm.Way) -> None:
        category, width = _resolve(w.tags)
        if category is None:
            return

        coords: list[tuple[float, float]] = []
        for node in w.nodes:
            if node.location.valid():
                coords.append(_project(node.location.lon, node.location.lat))

        if len(coords) < 2:
            return

        # Extra tags (road categories only; waterways don't carry these).
        hw = w.tags.get("highway", "")
        sidewalk = w.tags.get("sidewalk")        # left/right/both/no/None
        oneway   = w.tags.get("oneway", "no") in ("yes", "1", "true")
        lanes_raw = w.tags.get("lanes")
        lanes    = int(lanes_raw) if lanes_raw and lanes_raw.isdigit() \
                   else _DEFAULT_LANES.get(hw, 1)
        surface  = w.tags.get("surface")        # asphalt/concrete/unpaved/…
        bridge   = w.tags.get("bridge", "no") in ("yes", "1", "true", "viaduct")
        layer_raw = w.tags.get("layer", "0")
        layer    = int(layer_raw) if layer_raw.lstrip("-").isdigit() else 0

        self.features.append({
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": coords},
            "properties": {
                "category": category,
                "width":    width,
                "name":     w.tags.get("name"),
                "sidewalk": sidewalk,
                "oneway":   oneway,
                "lanes":    lanes,
                "surface":  surface,
                "bridge":   bridge,
                "layer":    layer,
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

    print("Extracting roads and waterways ...")
    handler = _RoadHandler()
    handler.apply_file(str(OSM_CLIPPED_PBF), locations=True, idx="flex_mem")
    print(f"  Extracted {len(handler.features)} features.")

    from collections import Counter
    counts = Counter(f["properties"]["category"] for f in handler.features)
    for cat, c in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"    {cat}: {c}")

    geojson = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "local_metres_utm31n"}},
        "features": handler.features,
    }

    ROADS_GEOJSON.parent.mkdir(parents=True, exist_ok=True)
    with open(ROADS_GEOJSON, "w", encoding="utf-8") as f:
        json.dump(geojson, f, separators=(",", ":"))

    print(f"Saved → {ROADS_GEOJSON}")


if __name__ == "__main__":
    main()
