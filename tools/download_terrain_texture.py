"""
download_terrain_texture.py — Download OSM raster tiles and stitch them into a
single terrain texture aligned to the world bounding box.

The output PNG has its top-left pixel at the NW corner and bottom-right at the
SE corner of the world bbox, which matches the UV layout of Terrain.gd exactly
(u=0→west, u=1→east, v=0→north, v=1→south).

Tiles are cached in output/osm_tiles/ and never re-downloaded.

Usage:
    python download_terrain_texture.py

Output:
    output/terrain_texture.png

Tile server:
    tile.openstreetmap.org — Standard OSM Mapnik tiles, free to use with proper
    attribution and caching.  See https://operations.osmfoundation.org/policies/tiles/
"""

import math
import time
from pathlib import Path

import requests
from PIL import Image
from tqdm import tqdm

from config import WORLD, OSM_TILE_CACHE_DIR, TERRAIN_TEXTURE_PNG

_TILE_URL      = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
_USER_AGENT    = "GrenobleOpenworld/1.0 (local dev; github.com/your-repo)"
_TILE_SIZE_PX  = 256
_REQUEST_DELAY = 0.05  # seconds between requests — be polite to the tile server


# ---------------------------------------------------------------------------
# Tile math
# ---------------------------------------------------------------------------

def _lon_to_tile_x(lon: float, zoom: int) -> int:
    return int((lon + 180.0) / 360.0 * (2 ** zoom))


def _lat_to_tile_y(lat: float, zoom: int) -> int:
    lat_rad = math.radians(lat)
    return int(
        (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi)
        / 2.0
        * (2 ** zoom)
    )


def _tile_nw_lon(x: int, zoom: int) -> float:
    return x / (2 ** zoom) * 360.0 - 180.0


def _tile_nw_lat(y: int, zoom: int) -> float:
    n = math.pi - 2.0 * math.pi * y / (2 ** zoom)
    return math.degrees(math.atan(math.sinh(n)))


def _lon_to_pixel(lon: float, tile_x0: int, zoom: int) -> float:
    """Pixel X within the stitched image for a given longitude."""
    tx = (lon + 180.0) / 360.0 * (2 ** zoom)
    return (tx - tile_x0) * _TILE_SIZE_PX


def _lat_to_pixel(lat: float, tile_y0: int, zoom: int) -> float:
    """Pixel Y within the stitched image for a given latitude."""
    lat_rad = math.radians(lat)
    ty = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) \
         / 2.0 * (2 ** zoom)
    return (ty - tile_y0) * _TILE_SIZE_PX


# ---------------------------------------------------------------------------
# Tile download
# ---------------------------------------------------------------------------

def _download_tile(z: int, x: int, y: int) -> Image.Image:
    cache_path = OSM_TILE_CACHE_DIR / str(z) / str(x) / f"{y}.png"
    if cache_path.exists():
        return Image.open(cache_path).convert("RGB")

    url = _TILE_URL.format(z=z, x=x, y=y)
    response = requests.get(
        url,
        headers={"User-Agent": _USER_AGENT},
        timeout=15,
    )
    response.raise_for_status()

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_bytes(response.content)
    time.sleep(_REQUEST_DELAY)

    return Image.open(cache_path).convert("RGB")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    zoom = WORLD.tile_zoom
    min_lon, min_lat, max_lon, max_lat = WORLD.bbox()

    # Tile range covering the bbox (note: tile Y increases southward)
    tx_min = _lon_to_tile_x(min_lon, zoom)
    tx_max = _lon_to_tile_x(max_lon, zoom)
    ty_min = _lat_to_tile_y(max_lat, zoom)  # north → smaller Y
    ty_max = _lat_to_tile_y(min_lat, zoom)  # south → larger Y

    n_x = tx_max - tx_min + 1
    n_y = ty_max - ty_min + 1
    total = n_x * n_y

    print(f"Zoom {zoom}: {n_x}×{n_y} = {total} tile(s) to download/load.")

    # --- Stitch tiles ---
    stitched_w = n_x * _TILE_SIZE_PX
    stitched_h = n_y * _TILE_SIZE_PX
    canvas = Image.new("RGB", (stitched_w, stitched_h))

    with tqdm(total=total, unit="tile") as bar:
        for ty in range(ty_min, ty_max + 1):
            for tx in range(tx_min, tx_max + 1):
                tile_img = _download_tile(zoom, tx, ty)
                px = (tx - tx_min) * _TILE_SIZE_PX
                py = (ty - ty_min) * _TILE_SIZE_PX
                canvas.paste(tile_img, (px, py))
                bar.update(1)

    # --- Crop to exact bbox ---
    left   = _lon_to_pixel(min_lon, tx_min, zoom)
    top    = _lat_to_pixel(max_lat, ty_min, zoom)
    right  = _lon_to_pixel(max_lon, tx_min, zoom)
    bottom = _lat_to_pixel(min_lat, ty_min, zoom)

    cropped = canvas.crop((int(left), int(top), int(right), int(bottom)))

    # --- Resize to target resolution ---
    size = WORLD.terrain_texture_size
    print(f"Crop: {cropped.size[0]}×{cropped.size[1]} px → resizing to {size}×{size}")
    final = cropped.resize((size, size), Image.LANCZOS)

    TERRAIN_TEXTURE_PNG.parent.mkdir(parents=True, exist_ok=True)
    final.save(TERRAIN_TEXTURE_PNG)
    print(f"Saved → {TERRAIN_TEXTURE_PNG}")


if __name__ == "__main__":
    main()
