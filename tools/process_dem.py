"""
process_dem.py — Merge DEM tiles, crop to world bbox, and export a 16-bit PNG heightmap.

The heightmap is a greyscale PNG where:
  - pixel value 0     → min elevation in the region
  - pixel value 65535 → max elevation in the region

Metadata (min/max elevation, world size in metres) is written alongside as
heightmap.json so Godot can reconstruct real elevations.

Usage:
    python process_dem.py

Output:
    output/heightmap.png    (1024×1024, 16-bit greyscale)
    output/heightmap.json   (metadata)
"""

import json
import sys

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.merge import merge
from rasterio.warp import calculate_default_transform, reproject
from rasterio.crs import CRS

from config import WORLD, DEM_RAW_DIR, IGN_DEM_TIFF, HEIGHTMAP_PNG, OUTPUT_DIR, LANDUSE_GEOJSON


_TARGET_CRS = CRS.from_epsg(32631)  # UTM zone 31N — metres


def _load_and_merge_tiles() -> tuple:
    """Open all DEM tiles, merge them, return (dataset, transform, crs)."""
    tif_files = sorted(DEM_RAW_DIR.glob("*.tif"))
    if not tif_files:
        print(f"No .tif files found in {DEM_RAW_DIR}", file=sys.stderr)
        sys.exit(1)

    print(f"Merging {len(tif_files)} tile(s) ...")
    datasets = [rasterio.open(f) for f in tif_files]
    mosaic, transform = merge(datasets)
    crs = datasets[0].crs
    for ds in datasets:
        ds.close()

    return mosaic, transform, crs


def _load_ign_tile() -> tuple:
    """Open the IGN RGE ALTI GeoTIFF, return (data, transform, crs)."""
    with rasterio.open(IGN_DEM_TIFF) as ds:
        data      = ds.read()
        transform = ds.transform
        crs       = ds.crs
    return data, transform, crs


def _reproject_to_utm(mosaic, src_transform, src_crs):
    """Reproject mosaic from WGS84 geographic to UTM zone 31N (metres)."""
    src_height, src_width = mosaic.shape[1], mosaic.shape[2]

    dst_transform, dst_width, dst_height = calculate_default_transform(
        src_crs, _TARGET_CRS,
        src_width, src_height,
        *rasterio.transform.array_bounds(src_height, src_width, src_transform),
    )

    dst_data = np.zeros((1, dst_height, dst_width), dtype=np.float32)

    reproject(
        source=mosaic,
        destination=dst_data,
        src_transform=src_transform,
        src_crs=src_crs,
        dst_transform=dst_transform,
        dst_crs=_TARGET_CRS,
        resampling=Resampling.bilinear,
    )

    return dst_data, dst_transform


def _crop_to_world(data, transform):
    """Crop the UTM raster to the world bounding box.

    Returns (cropped, world_width_m, world_height_m, cropped_transform)
    where cropped_transform maps pixel coords → absolute UTM 31N metres.
    """
    from pyproj import Transformer
    from rasterio.transform import from_bounds

    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
    min_lon, min_lat, max_lon, max_lat = WORLD.bbox()

    west, south = to_utm.transform(min_lon, min_lat)
    east, north = to_utm.transform(max_lon, max_lat)

    # Raster rows/cols for crop window
    row_off_top = max(0, int((north - transform.f) / transform.e))
    row_off_bot = max(0, int((south - transform.f) / transform.e))
    col_off_left = max(0, int((west - transform.c) / transform.a))
    col_off_right = max(0, int((east - transform.c) / transform.a))

    row_start = min(row_off_top, row_off_bot)
    row_end   = max(row_off_top, row_off_bot)
    col_start = min(col_off_left, col_off_right)
    col_end   = max(col_off_left, col_off_right)

    nrows = row_end - row_start
    ncols = col_end - col_start
    cropped = data[0, row_start:row_end, col_start:col_end]

    world_width_m  = abs(ncols * transform.a)
    world_height_m = abs(nrows * transform.e)
    cropped_transform = from_bounds(west, south, east, north, ncols, nrows)

    return cropped, world_width_m, world_height_m, cropped_transform


def _smooth_elevation(elevation: np.ndarray, sigma: float = 2.0) -> np.ndarray:
    """
    Apply a separable Gaussian blur to suppress DSM noise (building rooftops, tree canopy).
    sigma=2 at ~30 m/px ≈ 60 m smoothing — removes sub-block artefacts while
    preserving street-scale terrain variation and mountain shapes.
    """
    ksize = int(sigma * 4) * 2 + 1
    x = np.arange(ksize) - ksize // 2
    kernel = np.exp(-x ** 2 / (2 * sigma ** 2)).astype(np.float64)
    kernel /= kernel.sum()

    result = np.apply_along_axis(lambda r: np.convolve(r, kernel, mode="same"), axis=1, arr=elevation.astype(np.float64))
    result = np.apply_along_axis(lambda r: np.convolve(r, kernel, mode="same"), axis=0, arr=result)
    return result.astype(np.float32)


def _depress_water(elevation: np.ndarray, transform, depression_m: float = 2.5) -> np.ndarray:
    """Lower pixels that fall inside OSM water polygons by depression_m metres.

    Water polygons in landuse.geojson use local UTM 31N coords (metres from
    world centre).  This function offsets them to absolute UTM 31N so they
    align with the elevation array's transform.
    """
    import json
    from pyproj import Transformer
    from rasterio.features import rasterize as rio_rasterize
    from shapely.geometry import shape, mapping
    from shapely.affinity import translate

    if not LANDUSE_GEOJSON.exists():
        print("  landuse.geojson not found — skipping water depression.")
        return elevation

    with open(LANDUSE_GEOJSON) as f:
        geojson = json.load(f)

    # World centre in absolute UTM 31N.
    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
    cx, cy = to_utm.transform(WORLD.center_lon, WORLD.center_lat)

    water_shapes = []
    for feat in geojson.get("features", []):
        if feat["properties"].get("type") != "water":
            continue
        geom = shape(feat["geometry"])
        # local UTM (origin = world centre) → absolute UTM 31N
        geom = translate(geom, xoff=cx, yoff=cy)
        water_shapes.append(mapping(geom))

    if not water_shapes:
        print("  No water polygons found in landuse.geojson — skipping.")
        return elevation

    h, w = elevation.shape
    mask = rio_rasterize(
        [(g, 1) for g in water_shapes],
        out_shape=(h, w),
        transform=transform,
        fill=0,
        dtype=np.uint8,
    )

    n_pixels = int(mask.sum())
    print(f"  Depressing {n_pixels} water pixels by {depression_m} m.")
    result = elevation.copy()
    result[mask == 1] -= depression_m
    return result


def _normalise_to_16bit(elevation: np.ndarray) -> tuple[np.ndarray, float, float]:
    valid = elevation[elevation > -9000]  # exclude nodata
    elev_min = float(valid.min())
    elev_max = float(valid.max())

    normalised = np.clip((elevation - elev_min) / (elev_max - elev_min), 0.0, 1.0)
    uint16 = (normalised * 65535).astype(np.uint16)
    return uint16, elev_min, elev_max


def _save_png(data: np.ndarray, path) -> None:
    """Save a 2D uint16 array as a 16-bit greyscale PNG."""
    import struct, zlib

    height, width = data.shape

    def png_chunk(name: bytes, data: bytes) -> bytes:
        chunk = name + data
        return struct.pack(">I", len(data)) + chunk + struct.pack(">I", zlib.crc32(chunk) & 0xFFFFFFFF)

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", width, height, 16, 0, 0, 0, 0)
    ihdr = png_chunk(b"IHDR", ihdr_data)

    # Raw image data: filter byte 0x00 + big-endian uint16 pixels per row
    raw_rows = bytearray()
    for row in data:
        raw_rows.append(0)  # filter type None
        raw_rows += row.astype(">u2").tobytes()

    idat = png_chunk(b"IDAT", zlib.compress(bytes(raw_rows), level=6))
    iend = png_chunk(b"IEND", b"")

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(signature + ihdr + idat + iend)


def _resize(data: np.ndarray, size: int) -> np.ndarray:
    from PIL import Image
    img = Image.fromarray(data, mode="I;16")
    img = img.resize((size, size), Image.BILINEAR)
    return np.array(img, dtype=np.uint16)


def main() -> None:
    if IGN_DEM_TIFF.exists():
        print(f"Source: IGN RGE ALTI (DTM)  ← {IGN_DEM_TIFF.name}")
        mosaic, src_transform, src_crs = _load_ign_tile()
        is_dsm = False
    else:
        print("IGN DEM not found — falling back to Copernicus GLO-30 (DSM).")
        print("Run download_dem_ign.py for a cleaner terrain.")
        mosaic, src_transform, src_crs = _load_and_merge_tiles()
        is_dsm = True

    utm_data, utm_transform = _reproject_to_utm(mosaic, src_transform, src_crs)

    print("Cropping to world bbox ...")
    elevation, world_w, world_h, crop_transform = _crop_to_world(utm_data, utm_transform)

    print(
        f"Crop size: {elevation.shape[1]}×{elevation.shape[0]} px  "
        f"({world_w:.0f}×{world_h:.0f} m)"
    )

    if is_dsm:
        print("Smoothing elevation (Gaussian blur sigma=6 to suppress DSM noise) ...")
        elevation = _smooth_elevation(elevation, sigma=6.0)

    print("Depressing water bodies ...")
    elevation = _depress_water(elevation, crop_transform)

    uint16, elev_min, elev_max = _normalise_to_16bit(elevation)

    target_size = WORLD.heightmap_size
    print(f"Resampling to {target_size}×{target_size} ...")
    try:
        uint16 = _resize(uint16, target_size)
    except ImportError:
        # Fallback without Pillow — nearest-neighbour resize via numpy
        row_idx = (np.arange(target_size) * uint16.shape[0] / target_size).astype(int)
        col_idx = (np.arange(target_size) * uint16.shape[1] / target_size).astype(int)
        uint16 = uint16[np.ix_(row_idx, col_idx)]

    _save_png(uint16, HEIGHTMAP_PNG)
    print(f"Heightmap saved → {HEIGHTMAP_PNG}")

    metadata = {
        "heightmap_size": target_size,
        "world_width_m": round(world_w, 2),
        "world_height_m": round(world_h, 2),
        "elevation_min_m": round(elev_min, 2),
        "elevation_max_m": round(elev_max, 2),
        "center_lat": WORLD.center_lat,
        "center_lon": WORLD.center_lon,
    }
    meta_path = HEIGHTMAP_PNG.with_suffix(".json")
    with open(meta_path, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"Metadata saved  → {meta_path}")


if __name__ == "__main__":
    main()
