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

from config import (
    WORLD, DEM_RAW_DIR, IGN_DEM_TIFF, HEIGHTMAP_PNG, OUTPUT_DIR,
    LANDUSE_GEOJSON, ROADS_GEOJSON,
    DEM_FLAT_SIGMA, DEM_FLAT_GRADIENT_THRESHOLD,
)


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


def _apply_gaussian_2d(arr: np.ndarray, sigma: float) -> np.ndarray:
    """2-D Gaussian blur — uses scipy if available, else separable 1-D convolution."""
    try:
        from scipy.ndimage import gaussian_filter
        return gaussian_filter(arr.astype(np.float64), sigma=sigma)
    except ImportError:
        pass
    ksize = int(sigma * 4) * 2 + 1
    x = np.arange(ksize) - ksize // 2
    kernel = np.exp(-x ** 2 / (2 * sigma ** 2)).astype(np.float64)
    kernel /= kernel.sum()
    out = np.apply_along_axis(lambda r: np.convolve(r, kernel, mode="same"), axis=1, arr=arr.astype(np.float64))
    out = np.apply_along_axis(lambda r: np.convolve(r, kernel, mode="same"), axis=0, arr=out)
    return out


def _build_water_mask(shape: tuple, transform) -> np.ndarray:
    """Rasterize OSM water polygons into a binary uint8 mask (1 = water)."""
    import json
    from pyproj import Transformer
    from rasterio.features import rasterize as rio_rasterize
    from shapely.geometry import shape as shp_shape, mapping
    from shapely.affinity import translate

    if not LANDUSE_GEOJSON.exists():
        return np.zeros(shape, dtype=np.uint8)

    with open(LANDUSE_GEOJSON) as f:
        geojson = json.load(f)

    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
    cx, cy = to_utm.transform(WORLD.center_lon, WORLD.center_lat)

    water_shapes = []
    for feat in geojson.get("features", []):
        if feat["properties"].get("type") != "water":
            continue
        geom = shp_shape(feat["geometry"])
        geom = translate(geom, xoff=cx, yoff=cy)
        water_shapes.append(mapping(geom))

    if not water_shapes:
        return np.zeros(shape, dtype=np.uint8)

    h, w = shape
    return rio_rasterize(
        [(g, 1) for g in water_shapes],
        out_shape=(h, w),
        transform=transform,
        fill=0,
        dtype=np.uint8,
    )


def _smooth_flat_areas(
    elevation: np.ndarray,
    transform,
    sigma: float = 3.0,
    gradient_threshold: float = 0.5,
) -> np.ndarray:
    """Gaussian blur applied only on flat areas (low gradient), excluding water.

    Flat areas are detected by gradient magnitude < gradient_threshold (m/px).
    Water polygons are excluded from the flat mask so the river depression step
    is not undermined.  Mask edges are smoothed to avoid transition artefacts.
    """
    elev64 = elevation.astype(np.float64)

    # 1. Gradient magnitude (m/px)
    dy = np.gradient(elev64, axis=0)
    dx = np.gradient(elev64, axis=1)
    grad_mag = np.sqrt(dx ** 2 + dy ** 2)

    # 2. Raw flat mask
    flat_mask = (grad_mag < gradient_threshold).astype(np.float32)

    # 3. Exclude water bodies so river banks are not flattened
    water_mask = _build_water_mask(elevation.shape, transform)
    flat_mask[water_mask == 1] = 0.0

    # 4. Smooth mask edges to avoid hard transition artefacts
    smooth_mask = _apply_gaussian_2d(flat_mask, sigma=sigma).astype(np.float32)
    smooth_mask = np.clip(smooth_mask, 0.0, 1.0)

    # 5. Blur elevation
    blurred = _apply_gaussian_2d(elev64, sigma=sigma)

    # 6. Blend
    result = blurred * smooth_mask + elev64 * (1.0 - smooth_mask)

    n_flat = int((flat_mask > 0.5).sum())
    total  = flat_mask.size
    print(f"  Flat-area smoothing: {n_flat}/{total} px identified as flat "
          f"(threshold={gradient_threshold} m/px, sigma={sigma}).")
    return result.astype(np.float32)


def _flatten_roads(elevation: np.ndarray, transform) -> np.ndarray:
    """Flatten terrain transversally under roads.

    For each road segment, the elevation at the road centreline is sampled and
    stamped across the full road width perpendicularly to the road direction.
    The road can still slope longitudinally; only the cross-section is levelled.

    Roads coordinates in roads.geojson are local UTM 31N (metres from world
    centre), same convention as landuse.geojson.
    """
    import json
    from pyproj import Transformer

    if not ROADS_GEOJSON.exists():
        print("  roads.geojson not found — skipping road terrain flattening.")
        print("  Run extract_roads.py before process_dem.py to enable this.")
        return elevation

    with open(ROADS_GEOJSON) as f:
        geojson = json.load(f)

    to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32631", always_xy=True)
    cx, cy = to_utm.transform(WORLD.center_lon, WORLD.center_lat)

    h, w       = elevation.shape
    pixel_size = abs(float(transform.a))   # metres per pixel (east)

    reference = elevation.copy()   # sample centre elevations from unmodified array
    result    = elevation.copy()

    road_count = 0
    for feat in geojson.get("features", []):
        geom = feat.get("geometry", {})
        if geom.get("type") != "LineString":
            continue

        props      = feat.get("properties", {})
        road_width = float(props.get("width", 6.0))
        half_px    = max(1.0, (road_width / 2.0) / pixel_size)

        coords = geom.get("coordinates", [])
        if len(coords) < 2:
            continue

        # Local UTM → pixel (col, row)
        def _to_px(lx, ly):
            ax = lx + cx
            ay = ly + cy
            return (ax - transform.c) / transform.a, (ay - transform.f) / transform.e

        px_coords = [_to_px(c[0], c[1]) for c in coords]

        for i in range(len(px_coords) - 1):
            col0, row0 = px_coords[i]
            col1, row1 = px_coords[i + 1]

            dcol = col1 - col0
            drow = row1 - row0
            seg_len = np.hypot(dcol, drow)
            if seg_len < 0.5:
                continue

            dir_col = dcol / seg_len
            dir_row = drow / seg_len
            # Perpendicular (rotate 90°)
            perp_col = -dir_row
            perp_row =  dir_col

            # Sample one point per pixel along the segment
            n_s = max(2, int(seg_len) + 1)
            t   = np.linspace(0.0, 1.0, n_s)

            s_cols = col0 + t * dcol   # (n_s,)
            s_rows = row0 + t * drow

            # Clamp for safe sampling
            s_ci = np.clip(np.round(s_cols).astype(int), 0, w - 1)
            s_ri = np.clip(np.round(s_rows).astype(int), 0, h - 1)

            centre_elevs = reference[s_ri, s_ci]   # (n_s,)

            # Perpendicular offsets in pixel space
            n_perp = int(np.ceil(half_px))
            dp = np.arange(-n_perp, n_perp + 1, dtype=np.float64)   # (2*n_perp+1,)

            # All pixel positions: (n_s, 2*n_perp+1)
            all_cols = np.round(s_cols[:, None] + dp[None, :] * perp_col).astype(int)
            all_rows = np.round(s_rows[:, None] + dp[None, :] * perp_row).astype(int)

            valid = (all_cols >= 0) & (all_cols < w) & (all_rows >= 0) & (all_rows < h)

            elevs_2d = np.repeat(centre_elevs[:, None], 2 * n_perp + 1, axis=1)
            result[all_rows[valid], all_cols[valid]] = elevs_2d[valid]

        road_count += 1

    print(f"  Road terrain flattening: processed {road_count} roads.")
    return result


def _depress_water(elevation: np.ndarray, transform, depression_m: float = 2.5) -> np.ndarray:
    """Lower pixels that fall inside OSM water polygons by depression_m metres."""
    if not LANDUSE_GEOJSON.exists():
        print("  landuse.geojson not found — skipping water depression.")
        return elevation

    mask     = _build_water_mask(elevation.shape, transform)
    n_pixels = int(mask.sum())
    if n_pixels == 0:
        print("  No water polygons found in landuse.geojson — skipping.")
        return elevation

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

    print("Smoothing flat areas (adaptive gradient-based blur) ...")
    elevation = _smooth_flat_areas(
        elevation, crop_transform,
        sigma=DEM_FLAT_SIGMA,
        gradient_threshold=DEM_FLAT_GRADIENT_THRESHOLD,
    )

    print("Flattening terrain under roads ...")
    elevation = _flatten_roads(elevation, crop_transform)

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
