"""
extract_furniture.py — Extract street furniture nodes from the clipped OSM PBF.

Types extracted:
  highway=street_lamp     → "lamp"
  amenity=waste_basket    → "bin"
  amenity=bench           → "bench"
  highway=bus_stop        → "bus_stop"
  amenity=bicycle_parking → "bike"

Each feature is a GeoJSON Point with properties:
  type      : furniture type string (see above)
  direction : bearing in degrees from north, clockwise (may be null)

Coordinates are projected to local metres (UTM 31N, origin = world centre).

Usage:
    python extract_furniture.py

Output:
    output/furniture.geojson
"""

import json
import sys

import osmium
from pyproj import Transformer

from config import WORLD, OSM_CLIPPED_PBF, FURNITURE_GEOJSON


# ---------------------------------------------------------------------------
# Coordinate projection
# ---------------------------------------------------------------------------

_wgs84_to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
_cx, _cy = _wgs84_to_utm.transform(WORLD.center_lon, WORLD.center_lat)


def _project(lon: float, lat: float) -> tuple[float, float]:
    x, y = _wgs84_to_utm.transform(lon, lat)
    return x - _cx, y - _cy


# ---------------------------------------------------------------------------
# Tag → furniture type
# ---------------------------------------------------------------------------

def _resolve_type(tags: osmium.osm.TagList) -> str | None:
    hw = tags.get("highway", "")
    if hw == "street_lamp":
        return "lamp"
    if hw == "bus_stop":
        return "bus_stop"
    amenity = tags.get("amenity", "")
    if amenity == "waste_basket":
        return "bin"
    if amenity == "bench":
        return "bench"
    if amenity == "bicycle_parking":
        return "bike"
    return None


def _parse_direction(raw: str | None) -> float | None:
    """Parse OSM direction tag to float degrees (0=N, 90=E, 180=S, 270=W)."""
    if raw is None:
        return None
    # OSM direction can be numeric or cardinal (N, NE, E, …)
    _CARDINALS = {
        "N": 0, "NNE": 22.5, "NE": 45, "ENE": 67.5,
        "E": 90, "ESE": 112.5, "SE": 135, "SSE": 157.5,
        "S": 180, "SSW": 202.5, "SW": 225, "WSW": 247.5,
        "W": 270, "WNW": 292.5, "NW": 315, "NNW": 337.5,
    }
    upper = raw.strip().upper()
    if upper in _CARDINALS:
        return _CARDINALS[upper]
    try:
        return float(raw)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# OSM handler
# ---------------------------------------------------------------------------

class _FurnitureHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.features: list[dict] = []

    def node(self, n: osmium.osm.Node) -> None:
        ftype = _resolve_type(n.tags)
        if ftype is None:
            return
        if not n.location.valid():
            return

        x, y = _project(n.location.lon, n.location.lat)
        direction = _parse_direction(n.tags.get("direction"))

        self.features.append({
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [x, y]},
            "properties": {
                "type":      ftype,
                "direction": direction,
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

    print("Extracting street furniture ...")
    handler = _FurnitureHandler()
    handler.apply_file(str(OSM_CLIPPED_PBF))
    print(f"  Extracted {len(handler.features)} furniture items.")

    from collections import Counter
    counts = Counter(f["properties"]["type"] for f in handler.features)
    for t, c in sorted(counts.items(), key=lambda x: -x[1]):
        print(f"    {t}: {c}")

    geojson = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "local_metres_utm31n"}},
        "features": handler.features,
    }

    FURNITURE_GEOJSON.parent.mkdir(parents=True, exist_ok=True)
    with open(FURNITURE_GEOJSON, "w", encoding="utf-8") as f:
        json.dump(geojson, f, separators=(",", ":"))

    print(f"Saved → {FURNITURE_GEOJSON}")


if __name__ == "__main__":
    main()
