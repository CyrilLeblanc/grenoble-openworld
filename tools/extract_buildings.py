"""
extract_buildings.py — Convert the clipped OSM PBF into a GeoJSON of building footprints.

Follows the OSM Simple 3D Buildings spec (same logic as osmbuildings.org):

  - building=yes  → a standard building; rendered unless it is the outline of a
                    type=building relation OR contains building:part centroids
                    (has_parts=True), in which case it renders as a ground slab only.
  - building:part → an individual part; extruded from min_height_m to height_m.

has_parts detection — two complementary methods:
  1. Formal:   way is the outline member of a type=building relation (Pass 1).
  2. Informal: building polygon spatially contains the centroid of at least one
               building:part feature (Pass 3 — STRtree spatial index).
               This catches mappers who drew detailed parts without a relation.

Passes:
  1 — scan relations → collect outline way IDs
  2 — extract all building / part areas (keeps shapely geometries in memory)
  3 — spatial analysis → mark informal has_parts, then serialise to GeoJSON

Height resolution priority (same as osmbuildings.org):
  1. height tag  ("87", "87 m", "87.5")
  2. building:levels * 3 m
  3. None  → Godot falls back to its own default

Min-height resolution priority:
  1. min_height tag
  2. building:min_level * 3 m
  3. 0.0

Coordinates are projected to local metres (UTM 31N, origin = world centre).

Usage:
    python extract_buildings.py

Output:
    output/buildings.geojson
"""

import json
import sys

import osmium
import osmium.geom
from pyproj import Transformer
from shapely.geometry import mapping, Polygon
from shapely.strtree import STRtree
from shapely.wkb import loads as wkb_loads

from config import WORLD, OSM_CLIPPED_PBF, BUILDINGS_GEOJSON, EXCLUDED_WAY_IDS


# ---------------------------------------------------------------------------
# Coordinate projection
# ---------------------------------------------------------------------------

_wgs84_to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)

def _project(lon: float, lat: float) -> tuple[float, float]:
    cx, cy = _wgs84_to_utm.transform(WORLD.center_lon, WORLD.center_lat)
    x, y   = _wgs84_to_utm.transform(lon, lat)
    return x - cx, y - cy


# ---------------------------------------------------------------------------
# Pass 1 — identify building-relation outlines
# ---------------------------------------------------------------------------

class _RelationHandler(osmium.SimpleHandler):
    """Collect way IDs that are the outline member of a type=building relation."""

    def __init__(self) -> None:
        super().__init__()
        self.outline_way_ids: set[int] = set()

    def relation(self, r: osmium.osm.Relation) -> None:
        if r.tags.get("type") != "building":
            return
        for member in r.members:
            if member.type == "w" and member.role == "outline":
                self.outline_way_ids.add(member.ref)


# ---------------------------------------------------------------------------
# Pass 2 — extract building and part areas
# ---------------------------------------------------------------------------

# Internal record: shapely geometry kept alongside properties for Pass 3.
type _RawFeature = tuple[Polygon, dict]


class _BuildingHandler(osmium.SimpleHandler):
    def __init__(self, outline_way_ids: set[int]) -> None:
        super().__init__()
        self._outline_way_ids = outline_way_ids
        self.raw: list[_RawFeature] = []
        self._wkb_factory = osmium.geom.WKBFactory()

    def area(self, area: osmium.osm.Area) -> None:
        if area.orig_id() in EXCLUDED_WAY_IDS:
            return

        tags = area.tags
        is_building = "building" in tags and tags.get("building") != "no"
        is_part     = tags.get("building:part", "no") not in ("no", "")

        if not is_building and not is_part:
            return

        try:
            wkb = self._wkb_factory.create_multipolygon(area)
        except Exception:
            return

        geom = wkb_loads(wkb, hex=True)

        def project_ring(coords):
            return [_project(lon, lat) for lon, lat in coords]

        projected = []
        for polygon in (geom.geoms if geom.geom_type == "MultiPolygon" else [geom]):
            exterior  = project_ring(polygon.exterior.coords)
            interiors = [project_ring(ring.coords) for ring in polygon.interiors]
            projected.append(Polygon(exterior, interiors))

        if not projected:
            return

        footprint = max(projected, key=lambda p: p.area)

        self.raw.append((footprint, {
            "building":     tags.get("building"),
            "is_part":      is_part,
            "has_parts":    area.orig_id() in self._outline_way_ids,  # formal detection
            "height_m":     _parse_height(tags),
            "min_height_m": _parse_min_height(tags),
            "levels":       _parse_int(tags.get("building:levels")),
            "material":     tags.get("building:material"),
            "wall_colour":  tags.get("building:colour") or tags.get("building:color"),
            "roof_colour":  tags.get("roof:colour") or tags.get("roof:color"),
            "roof_shape":   tags.get("roof:shape"),
            "name":         tags.get("name"),
        }))


# ---------------------------------------------------------------------------
# Pass 3 — informal has_parts detection via spatial containment
# ---------------------------------------------------------------------------

def _detect_informal_parts(raw: list[_RawFeature]) -> int:
    """
    For every building=yes polygon, check whether any building:part centroid
    falls inside it. If so, mark has_parts=True (informal — no relation needed).

    Uses a shapely STRtree for efficient spatial lookup.
    Returns the number of buildings newly marked.
    """
    buildings = [(i, geom, props)
                 for i, (geom, props) in enumerate(raw)
                 if not props["is_part"]]
    parts     = [(geom, props)
                 for geom, props in raw
                 if props["is_part"]]

    if not buildings or not parts:
        return 0

    building_geoms = [geom for _, geom, _ in buildings]
    tree = STRtree(building_geoms)

    newly_marked = 0
    for part_geom, _ in parts:
        centroid = part_geom.centroid
        # query_items returns indices into building_geoms whose envelope intersects.
        for idx in tree.query(centroid):
            if not buildings[idx][2]["has_parts"] and building_geoms[idx].contains(centroid):
                buildings[idx][2]["has_parts"] = True
                newly_marked += 1

    return newly_marked


# ---------------------------------------------------------------------------
# Tag parsing helpers
# ---------------------------------------------------------------------------

def _parse_height(tags: osmium.osm.TagList) -> float | None:
    """
    Parse absolute height in metres.
    Accepts: "87", "87 m", "87.5 m".
    Falls back to building:levels * 3 if no explicit height tag.
    Returns None when unknown (Godot will apply its own default).
    """
    raw = tags.get("height")
    if raw:
        try:
            return float(raw.split()[0])
        except (ValueError, IndexError):
            pass

    levels = _parse_int(tags.get("building:levels"))
    if levels is not None:
        return float(levels) * 3.0

    return None


def _parse_min_height(tags: osmium.osm.TagList) -> float:
    """
    Parse the base height above local ground.
    Accepts: "min_height" tag or building:min_level * 3 m.
    Returns 0.0 when absent (feature starts at ground).
    """
    raw = tags.get("min_height")
    if raw:
        try:
            return float(raw.split()[0])
        except (ValueError, IndexError):
            pass

    min_level = _parse_int(tags.get("building:min_level"))
    if min_level is not None:
        return float(min_level) * 3.0

    return 0.0


def _parse_int(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return None


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

    print("Pass 1: scanning relations ...")
    rel_handler = _RelationHandler()
    rel_handler.apply_file(str(OSM_CLIPPED_PBF))
    print(f"  Found {len(rel_handler.outline_way_ids)} formal building-relation outline(s).")

    print("Pass 2: extracting building areas ...")
    bld_handler = _BuildingHandler(rel_handler.outline_way_ids)
    bld_handler.apply_file(str(OSM_CLIPPED_PBF), locations=True, idx="flex_mem")
    n_parts     = sum(1 for _, p in bld_handler.raw if p["is_part"])
    n_buildings = len(bld_handler.raw) - n_parts
    print(f"  Extracted {n_buildings} buildings, {n_parts} building:part features.")

    print("Pass 3: detecting informal building groups (spatial containment) ...")
    newly_marked = _detect_informal_parts(bld_handler.raw)
    print(f"  Marked {newly_marked} additional building(s) as has_parts via spatial detection.")

    features = [
        {"type": "Feature", "geometry": mapping(geom), "properties": props}
        for geom, props in bld_handler.raw
    ]

    geojson = {
        "type": "FeatureCollection",
        "crs": {"type": "name", "properties": {"name": "local_metres_utm31n"}},
        "features": features,
    }

    BUILDINGS_GEOJSON.parent.mkdir(parents=True, exist_ok=True)
    with open(BUILDINGS_GEOJSON, "w", encoding="utf-8") as f:
        json.dump(geojson, f, separators=(",", ":"))

    print(f"Saved → {BUILDINGS_GEOJSON}")


if __name__ == "__main__":
    main()
