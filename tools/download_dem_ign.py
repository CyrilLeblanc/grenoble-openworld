"""
download_dem_ign.py — Download IGN RGE ALTI 1m DTM via the Géoplateforme WMTS.

The IGN Géoplateforme exposes elevation data as BIL (Band Interleaved by Line)
32-bit float tiles through its WMTS service.  No authentication required.

Layer  : ELEVATION.ELEVATIONGRIDCOVERAGE.HIGHRES  (RGE ALTI 1m — true DTM)
Format : image/x-bil;bits=32  (raw float32, 256×256 px per tile)
Set    : WGS84G_6_14  (zoom levels 6–14, ~4.7 m/px at zoom 14, lat 45°)

Workflow:
  1. Fetch GetCapabilities to get exact tile matrix geometry for level 14.
  2. Compute which tiles cover the world bbox.
  3. Download tiles in parallel (typically 100–150 tiles, ~25 MB).
  4. Stitch into a Float32 GeoTIFF → output/ign_rge_alti.tif.

process_dem.py then reprojects to UTM 31N, depresses water bodies, and exports
the final 1024×1024 heightmap.

Usage:
    python download_dem_ign.py

Output:
    output/ign_rge_alti.tif   (Float32 GeoTIFF, WGS84 / EPSG:4326)
"""

import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from xml.etree import ElementTree as ET

import numpy as np
import requests
import rasterio
from rasterio.crs import CRS
from rasterio.transform import from_bounds

from config import WORLD, OUTPUT_DIR, IGN_DEM_TIFF

_WMTS_BASE   = "https://data.geopf.fr/wmts"
_LAYER       = "ELEVATION.ELEVATIONGRIDCOVERAGE.HIGHRES"
_STYLE       = "normal"
_FORMAT      = "image/x-bil;bits=32"
_MATRIXSET   = "WGS84G_6_14"
_TILE_LEVEL  = "14"
_TILE_PIXELS = 256
_NODATA      = -99999.0
_MAX_WORKERS = 8


# ---------------------------------------------------------------------------
# WMTS capabilities
# ---------------------------------------------------------------------------

def _get_capabilities() -> ET.Element:
    url = f"{_WMTS_BASE}?SERVICE=WMTS&VERSION=1.0.0&REQUEST=GetCapabilities"
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    return ET.fromstring(resp.content)


def _parse_tile_matrix(root: ET.Element) -> dict:
    """
    Find the TileMatrix for our level in the WGS84G_6_14 set.
    Returns a dict with keys: tl_lon, tl_lat, tile_deg_w, tile_deg_h,
    matrix_width, matrix_height, tile_pixels.
    """
    wmts = "http://www.opengis.net/wmts/1.0"
    ows  = "http://www.opengis.net/ows/1.1"

    for tms in root.iter(f"{{{wmts}}}TileMatrixSet"):
        id_el = tms.find(f"{{{ows}}}Identifier")
        if id_el is None or id_el.text != _MATRIXSET:
            continue

        for tm in tms.findall(f"{{{wmts}}}TileMatrix"):
            id_el = tm.find(f"{{{ows}}}Identifier")
            if id_el is None or id_el.text != _TILE_LEVEL:
                continue

            parts = tm.find(f"{{{wmts}}}TopLeftCorner").text.split()
            a, b  = float(parts[0]), float(parts[1])
            # Handle both (lon, lat) and (lat, lon) axis orders:
            # whichever value is outside [-90, 90] is the longitude.
            if abs(a) > 90:
                tl_lon, tl_lat = a, b
            elif abs(b) > 90:
                tl_lon, tl_lat = b, a
            else:
                tl_lon, tl_lat = a, b  # both in range — assume lon first

            mw = int(tm.find(f"{{{wmts}}}MatrixWidth").text)
            mh = int(tm.find(f"{{{wmts}}}MatrixHeight").text)
            tw = int(tm.find(f"{{{wmts}}}TileWidth").text)

            return {
                "tl_lon":        tl_lon,
                "tl_lat":        tl_lat,
                "tile_deg_w":    360.0 / mw,
                "tile_deg_h":    180.0 / mh,
                "matrix_width":  mw,
                "matrix_height": mh,
                "tile_pixels":   tw,
            }

    raise RuntimeError(
        f"TileMatrix '{_TILE_LEVEL}' not found in TileMatrixSet '{_MATRIXSET}'."
    )


def _fallback_matrix() -> dict:
    """Hardcoded parameters for WGS84G zoom 14 (used if capabilities parse fails)."""
    mw, mh = 2 ** 15, 2 ** 14          # 32768 × 16384
    return {
        "tl_lon": -180.0, "tl_lat": 90.0,
        "tile_deg_w": 360.0 / mw, "tile_deg_h": 180.0 / mh,
        "matrix_width": mw, "matrix_height": mh,
        "tile_pixels": _TILE_PIXELS,
    }


# ---------------------------------------------------------------------------
# Tile download
# ---------------------------------------------------------------------------

def _download_tile(col: int, row: int) -> tuple[int, int, bytes | None]:
    params = {
        "SERVICE":       "WMTS",
        "VERSION":       "1.0.0",
        "REQUEST":       "GetTile",
        "LAYER":         _LAYER,
        "STYLE":         _STYLE,
        "FORMAT":        _FORMAT,
        "TILEMATRIXSET": _MATRIXSET,
        "TILEMATRIX":    _TILE_LEVEL,
        "TILEROW":       str(row),
        "TILECOL":       str(col),
    }
    expected = _TILE_PIXELS * _TILE_PIXELS * 4
    try:
        resp = requests.get(_WMTS_BASE, params=params, timeout=30)
        if resp.status_code == 200 and len(resp.content) == expected:
            return col, row, resp.content
        return col, row, None
    except Exception:
        return col, row, None


def _decode_bil(raw: bytes) -> np.ndarray:
    """Decode a raw BIL float32 tile to (H, W) float32, nodata → NaN."""
    arr = np.frombuffer(raw, dtype="<f4").reshape(_TILE_PIXELS, _TILE_PIXELS).copy()
    arr[arr <= _NODATA + 1] = np.nan
    return arr


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if IGN_DEM_TIFF.exists():
        print(f"Already cached: {IGN_DEM_TIFF}")
        return

    print("Fetching WMTS GetCapabilities ...")
    try:
        root = _get_capabilities()
        tm   = _parse_tile_matrix(root)
        print(f"  Tile size: {tm['tile_pixels']}×{tm['tile_pixels']} px  "
              f"res: {tm['tile_deg_w']:.6f}° × {tm['tile_deg_h']:.6f}°/tile")
    except Exception as exc:
        print(f"  Warning: capabilities parse failed ({exc}) — using hardcoded defaults.")
        tm = _fallback_matrix()

    tl_lon, tl_lat  = tm["tl_lon"], tm["tl_lat"]
    tdw, tdh        = tm["tile_deg_w"], tm["tile_deg_h"]
    px              = tm["tile_pixels"]

    min_lon, min_lat, max_lon, max_lat = WORLD.bbox()

    # Inclusive tile range.
    col0 = int((min_lon - tl_lon) / tdw)
    col1 = int((max_lon - tl_lon) / tdw)
    row0 = int((tl_lat - max_lat) / tdh)
    row1 = int((tl_lat - min_lat) / tdh)

    ncols, nrows = col1 - col0 + 1, row1 - row0 + 1
    n_tiles = ncols * nrows

    print(
        f"  Bbox: {min_lon:.5f},{min_lat:.5f} → {max_lon:.5f},{max_lat:.5f}\n"
        f"  Tiles: cols {col0}–{col1}, rows {row0}–{row1}  "
        f"({ncols}×{nrows} = {n_tiles} tiles)"
    )

    # Allocate output (NaN = missing).
    mosaic = np.full((nrows * px, ncols * px), np.nan, dtype=np.float32)

    print(f"Downloading {n_tiles} tiles ...")
    tasks = [(c, r) for r in range(row0, row1 + 1) for c in range(col0, col1 + 1)]

    with ThreadPoolExecutor(max_workers=_MAX_WORKERS) as pool:
        futures = {pool.submit(_download_tile, c, r): (c, r) for c, r in tasks}
        done, failed = 0, 0
        for fut in as_completed(futures):
            col, row, raw = fut.result()
            done += 1
            print(f"\r  {done}/{n_tiles}  (failed: {failed})", end="", flush=True)
            if raw is None:
                failed += 1
                continue
            tile = _decode_bil(raw)
            py = (row - row0) * px
            px_ = (col - col0) * px
            mosaic[py : py + px, px_ : px_ + px] = tile
    print()

    if failed:
        print(f"  Warning: {failed} tile(s) missing — filled with nodata.")

    # Replace NaN with nodata sentinel for rasterio.
    mosaic = np.where(np.isnan(mosaic), _NODATA, mosaic)

    # Affine transform for the stitched mosaic.
    west  = tl_lon + col0 * tdw
    north = tl_lat - row0 * tdh
    east  = tl_lon + (col1 + 1) * tdw
    south = tl_lat - (row1 + 1) * tdh
    transform = from_bounds(west, south, east, north, ncols * px, nrows * px)

    print(f"Saving GeoTIFF ({ncols * px}×{nrows * px} px) ...")
    with rasterio.open(
        IGN_DEM_TIFF, "w",
        driver="GTiff",
        height=nrows * px, width=ncols * px,
        count=1, dtype="float32",
        crs=CRS.from_epsg(4326),
        transform=transform,
        nodata=_NODATA,
        compress="deflate",
    ) as dst:
        dst.write(mosaic[np.newaxis, :, :])

    size_mb = IGN_DEM_TIFF.stat().st_size / 1024 / 1024
    print(f"Saved → {IGN_DEM_TIFF}  ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
