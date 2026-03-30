"""
generate_landuse_texture.py — Rasterise landuse GeoJSON into a terrain color texture.

Each pixel maps to a world position (same grid as heightmap.png).
Polygons are drawn in priority order so higher-priority types paint over lower ones.

Pixel coordinate convention (matches Terrain.gd UV sampling):
  px = int((easting  / world_width_m  + 0.5) * size)   # 0=west,  1=east
  py = int((0.5 - northing / world_height_m) * size)   # 0=north, 1=south

Usage:
    python generate_landuse_texture.py

Output:
    output/landuse_texture.png
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

from config import HEIGHTMAP_PNG, LANDUSE_GEOJSON, LANDUSE_TEXTURE_PNG


# ---------------------------------------------------------------------------
# Colors (RGB tuples, matching LanduseMeshSpawner palette)
# ---------------------------------------------------------------------------

BACKGROUND = (158, 148, 128)   # neutral sandy terrain

_TYPE_COLOR: dict[str, tuple[int, int, int]] = {
    "grass":       (115, 166,  71),
    "farmland":    (184, 166,  89),
    "industrial":  (158, 158, 153),
    "wetland":     ( 77, 133,  97),
    "park":        ( 89, 153,  64),
    "sports":      (102, 184,  71),
    "water":       ( 71, 133, 199),
    "wood":        ( 38,  89,  31),
}

# Draw order: lowest priority first (painted over by higher tiers).
_DRAW_ORDER: list[str] = [
    "industrial",
    "farmland",
    "grass",
    "wetland",
    "park",
    "sports",
    "water",
    "wood",
]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    # Read world dimensions from heightmap metadata.
    meta_path = HEIGHTMAP_PNG.with_suffix(".json")
    if not meta_path.exists():
        print(f"heightmap.json not found at {meta_path}\nRun process_dem.py first.", file=sys.stderr)
        sys.exit(1)

    with open(meta_path) as f:
        meta = json.load(f)

    size: int         = meta["heightmap_size"]       # 1024
    world_w: float    = meta["world_width_m"]
    world_h: float    = meta["world_height_m"]

    if not LANDUSE_GEOJSON.exists():
        print(f"landuse.geojson not found at {LANDUSE_GEOJSON}\nRun extract_landuse.py first.", file=sys.stderr)
        sys.exit(1)

    with open(LANDUSE_GEOJSON) as f:
        geojson = json.load(f)

    features = geojson.get("features", [])
    print(f"Rasterising {len(features)} landuse features at {size}×{size} px ...")

    # Group features by type.
    by_type: dict[str, list] = {t: [] for t in _TYPE_COLOR}
    for feat in features:
        t = feat.get("properties", {}).get("type", "")
        if t in by_type:
            by_type[t].append(feat)

    # Create image with background color.
    img  = Image.new("RGB", (size, size), BACKGROUND)
    draw = ImageDraw.Draw(img)

    def world_to_px(easting: float, northing: float) -> tuple[int, int]:
        px = int((easting  / world_w + 0.5) * size)
        py = int((0.5 - northing / world_h) * size)
        return (px, py)

    # Rasterise in draw order.
    drawn = 0
    for landuse_type in _DRAW_ORDER:
        color = _TYPE_COLOR[landuse_type]
        for feat in by_type.get(landuse_type, []):
            geom = feat.get("geometry", {})
            if geom.get("type") != "Polygon":
                continue
            rings = geom.get("coordinates", [])
            if not rings or len(rings[0]) < 3:
                continue
            pixels = [world_to_px(c[0], c[1]) for c in rings[0]]
            draw.polygon(pixels, fill=color)
            drawn += 1

    print(f"  Drew {drawn} polygons.")

    LANDUSE_TEXTURE_PNG.parent.mkdir(parents=True, exist_ok=True)
    img.save(LANDUSE_TEXTURE_PNG)
    print(f"Saved → {LANDUSE_TEXTURE_PNG}")


if __name__ == "__main__":
    main()
