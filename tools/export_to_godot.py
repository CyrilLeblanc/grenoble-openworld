"""
export_to_godot.py — Copy pipeline outputs into the Godot project's data/ folder.

Usage:
    python export_to_godot.py

Copies:
    output/heightmap.png  → ../data/heightmap.png
    output/heightmap.json → ../data/heightmap.json
    output/buildings.geojson → ../data/buildings.geojson
"""

import shutil
import sys
from pathlib import Path

from config import HEIGHTMAP_PNG, BUILDINGS_GEOJSON, LANDUSE_GEOJSON, LANDUSE_TEXTURE_PNG, ROADS_GEOJSON, TREES_GEOJSON, GODOT_DATA_DIR


_EXPORTS = [
    (HEIGHTMAP_PNG,                     GODOT_DATA_DIR / "heightmap.png"),
    (HEIGHTMAP_PNG.with_suffix(".json"), GODOT_DATA_DIR / "heightmap.json"),
    (BUILDINGS_GEOJSON,                 GODOT_DATA_DIR / "buildings.geojson"),
    (LANDUSE_GEOJSON,                   GODOT_DATA_DIR / "landuse.geojson"),
    (LANDUSE_TEXTURE_PNG,               GODOT_DATA_DIR / "landuse_texture.png"),
    (ROADS_GEOJSON,                     GODOT_DATA_DIR / "roads.geojson"),
    (TREES_GEOJSON,                     GODOT_DATA_DIR / "trees.geojson"),
]


def main() -> None:
    GODOT_DATA_DIR.mkdir(parents=True, exist_ok=True)
    all_ok = True

    for src, dst in _EXPORTS:
        if not src.exists():
            print(f"  MISSING  {src}", file=sys.stderr)
            all_ok = False
            continue
        shutil.copy2(src, dst)
        print(f"  Copied   {src.name} → {dst}")

    if not all_ok:
        print("\nSome files were missing. Run the pipeline scripts first.")
        sys.exit(1)

    print("\nAll assets exported to Godot data/ folder.")


if __name__ == "__main__":
    main()
