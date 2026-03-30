"""
download_dem.py — Download Copernicus GLO-30 DEM tiles covering the world bbox.

Copernicus GLO-30 tiles are 1°×1° GeoTIFFs freely available via AWS S3 (no auth).
Tile naming: Copernicus_DSM_COG_10_N{lat:02d}_00_E{lon:03d}_00_DEM.tif

Usage:
    python download_dem.py

Output:
    output/dem_tiles/*.tif   (one file per 1° tile)
"""

import math
from pathlib import Path

import requests
from tqdm import tqdm

from config import WORLD, DEM_RAW_DIR

# Copernicus GLO-30 on AWS — no authentication required
_TILE_URL = (
    "https://copernicus-dem-30m.s3.amazonaws.com/"
    "Copernicus_DSM_COG_10_{lat_tag}_00_{lon_tag}_00_DEM/"
    "Copernicus_DSM_COG_10_{lat_tag}_00_{lon_tag}_00_DEM.tif"
)


def _tile_tags(lat_floor: int, lon_floor: int) -> tuple[str, str]:
    lat_tag = f"{'N' if lat_floor >= 0 else 'S'}{abs(lat_floor):02d}"
    lon_tag = f"{'E' if lon_floor >= 0 else 'W'}{abs(lon_floor):03d}"
    return lat_tag, lon_tag


def _tiles_for_bbox(bbox: tuple) -> list[tuple[int, int]]:
    """Return list of (lat_floor, lon_floor) 1° tile corners covering bbox."""
    min_lon, min_lat, max_lon, max_lat = bbox
    tiles = []
    for lat in range(math.floor(min_lat), math.ceil(max_lat)):
        for lon in range(math.floor(min_lon), math.ceil(max_lon)):
            tiles.append((lat, lon))
    return tiles


def download_tile(lat_floor: int, lon_floor: int, dest_dir: Path) -> Path:
    lat_tag, lon_tag = _tile_tags(lat_floor, lon_floor)
    filename = f"Copernicus_DSM_COG_10_{lat_tag}_00_{lon_tag}_00_DEM.tif"
    dest = dest_dir / filename

    if dest.exists():
        print(f"  {filename} already cached, skipping.")
        return dest

    url = _TILE_URL.format(lat_tag=lat_tag, lon_tag=lon_tag)
    print(f"  Downloading {filename} ...")

    response = requests.get(url, stream=True, timeout=60)
    response.raise_for_status()

    total = int(response.headers.get("content-length", 0))
    with open(dest, "wb") as f, tqdm(
        total=total, unit="B", unit_scale=True, unit_divisor=1024, leave=False
    ) as bar:
        for chunk in response.iter_content(chunk_size=1024 * 256):
            f.write(chunk)
            bar.update(len(chunk))

    return dest


def main() -> None:
    DEM_RAW_DIR.mkdir(parents=True, exist_ok=True)

    bbox = WORLD.bbox()
    tiles = _tiles_for_bbox(bbox)
    print(f"Bbox: {bbox}")
    print(f"Tiles to download: {len(tiles)}")

    for lat_floor, lon_floor in tiles:
        download_tile(lat_floor, lon_floor, DEM_RAW_DIR)

    print("Done — DEM tiles saved to", DEM_RAW_DIR)


if __name__ == "__main__":
    main()
