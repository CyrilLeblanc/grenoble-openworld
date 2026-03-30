"""
download_osm.py — Download the Rhône-Alpes OSM PBF and clip it to the world bbox.

Usage:
    python download_osm.py [--skip-download]

    --skip-download   Skip the large PBF download if it already exists locally.

Output:
    output/rhone-alpes-latest.osm.pbf   (raw, ~400 MB)
    output/grenoble.osm.pbf             (clipped to world bbox)
"""

import argparse
import subprocess
import sys
from pathlib import Path

import requests
from tqdm import tqdm

from config import WORLD, OSM_SOURCE_PBF, OSM_CLIPPED_PBF, OUTPUT_DIR

OSM_DOWNLOAD_URL = (
    "https://download.geofabrik.de/europe/france/rhone-alpes-latest.osm.pbf"
)


def download_pbf(url: str, dest: Path) -> None:
    print(f"Downloading {url} ...")
    response = requests.get(url, stream=True, timeout=60)
    response.raise_for_status()

    total = int(response.headers.get("content-length", 0))
    dest.parent.mkdir(parents=True, exist_ok=True)

    with open(dest, "wb") as f, tqdm(
        total=total, unit="B", unit_scale=True, unit_divisor=1024
    ) as bar:
        for chunk in response.iter_content(chunk_size=1024 * 256):
            f.write(chunk)
            bar.update(len(chunk))

    print(f"Saved to {dest}")


def clip_pbf(source: Path, dest: Path, bbox: tuple) -> None:
    """Use osmium to extract the bbox from the full PBF."""
    min_lon, min_lat, max_lon, max_lat = bbox
    bbox_str = f"{min_lon},{min_lat},{max_lon},{max_lat}"

    print(f"Clipping to bbox {bbox_str} ...")
    result = subprocess.run(
        [
            "osmium", "extract",
            "--bbox", bbox_str,
            "--output", str(dest),
            "--overwrite",
            str(source),
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print("osmium stderr:", result.stderr, file=sys.stderr)
        raise RuntimeError("osmium extract failed")

    print(f"Clipped PBF saved to {dest}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Download and clip OSM data.")
    parser.add_argument(
        "--skip-download",
        action="store_true",
        help="Skip downloading the source PBF if it already exists.",
    )
    args = parser.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if args.skip_download and OSM_SOURCE_PBF.exists():
        print(f"Skipping download — using existing {OSM_SOURCE_PBF}")
    else:
        download_pbf(OSM_DOWNLOAD_URL, OSM_SOURCE_PBF)

    clip_pbf(OSM_SOURCE_PBF, OSM_CLIPPED_PBF, WORLD.bbox())


if __name__ == "__main__":
    main()
