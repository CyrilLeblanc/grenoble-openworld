"""
generate_facade_atlas.py — Download CC0 wall textures and assemble a facade atlas.

Downloads 1K albedo maps from Poly Haven (polyhaven.com, CC0) for eight wall
material types, then stitches them side-by-side into a single 4096×512 PNG.

Atlas layout — 8 slots of 512×512 px, left to right:
  0  plaster / enduit         (residential default)
  1  brick red                (building:material=brick)
  2  brick beige              (brick, second variant)
  3  concrete smooth          (building:material=concrete, commercial)
  4  concrete rough / béton   (industrial)
  5  limestone / pierre       (building:material=stone, civic)
  6  stone / roche            (stone, second variant)
  7  metal / corrugated iron  (building:material=metal, industrial)

If a Poly Haven download fails the slot falls back to a neutral solid colour
so the game still runs.  Delete the output file and re-run to retry downloads.

Usage:
    python generate_facade_atlas.py

Output:
    output/facade_atlas.png  (4096 × 512 px, RGBA)
"""

import sys
from io import BytesIO
from pathlib import Path
from typing import Optional

import requests
from PIL import Image

from config import OUTPUT_DIR, FACADE_ATLAS_PNG

_PH_API      = "https://api.polyhaven.com"
_N_SLOTS     = 8
_SLOT_W      = 512
_SLOT_H      = 512

# ---------------------------------------------------------------------------
# Slot definitions
# ---------------------------------------------------------------------------
# (slot, name, polyhaven_category, result_index, fallback_rgb)
# result_index: which item from the sorted category list to use.
# Poly Haven sorts by date added (newest first) — index 0 = most recent upload.
# Use higher indices to pick different variants within the same category.
_SLOTS = [
    (0, "plaster",         "plaster",  0, (224, 212, 194)),
    (1, "brick_red",       "brick",    0, (173,  87,  63)),
    (2, "brick_beige",     "brick",    2, (203, 169, 128)),
    (3, "concrete_smooth", "concrete", 0, (158, 158, 158)),
    (4, "concrete_rough",  "concrete", 2, (143, 139, 133)),
    (5, "limestone",       "rock",     0, (204, 194, 168)),
    (6, "rock_stone",      "rock",     3, (161, 154, 144)),
    (7, "metal",           "metal",    0, (141, 138, 133)),
]

# ---------------------------------------------------------------------------
# Poly Haven helpers
# ---------------------------------------------------------------------------

def _ph_list_category(category: str) -> list[str]:
    """Return slugs for a Poly Haven texture category (newest first)."""
    resp = requests.get(
        f"{_PH_API}/assets",
        params={"type": "textures", "categories": category},
        timeout=15,
    )
    resp.raise_for_status()
    return list(resp.json().keys())


def _ph_diffuse_url(slug: str) -> Optional[str]:
    """Return the 1K PNG diffuse/albedo URL for a slug, or None."""
    resp = requests.get(f"{_PH_API}/files/{slug}", timeout=15)
    if resp.status_code != 200:
        return None
    try:
        data = resp.json()
        # API structure: { "Diffuse": { "1k": { "png": { "url": "..." } } } }
        for key in ("Diffuse", "diffuse", "diff", "col", "color", "albedo"):
            if key in data:
                return data[key]["1k"]["png"]["url"]
    except (KeyError, TypeError):
        pass
    return None


def _download_image(url: str) -> Optional[Image.Image]:
    resp = requests.get(url, timeout=60)
    return Image.open(BytesIO(resp.content)).convert("RGB") if resp.status_code == 200 else None


# ---------------------------------------------------------------------------
# Per-slot fetch
# ---------------------------------------------------------------------------

def _fetch_slot(category: str, result_index: int) -> Optional[Image.Image]:
    try:
        slugs = _ph_list_category(category)
    except Exception as exc:
        print(f"    Category '{category}' query failed: {exc}")
        return None

    if not slugs:
        print(f"    No textures found for category '{category}'.")
        return None

    idx   = min(result_index, len(slugs) - 1)
    slug  = slugs[idx]
    print(f"    '{category}'[{idx}] → '{slug}'", end=" ", flush=True)

    try:
        url = _ph_diffuse_url(slug)
        if url is None:
            print("→ no diffuse URL")
            return None
        img = _download_image(url)
        if img is None:
            print("→ download failed")
            return None
        print("→ ok")
        return img.resize((_SLOT_W, _SLOT_H), Image.LANCZOS)
    except Exception as exc:
        print(f"→ error: {exc}")
        return None


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if FACADE_ATLAS_PNG.exists():
        print(f"Already exists: {FACADE_ATLAS_PNG}")
        print("Delete it and re-run to refresh textures.")
        return

    atlas = Image.new("RGB", (_N_SLOTS * _SLOT_W, _SLOT_H))

    for slot_idx, name, category, result_index, fallback_rgb in _SLOTS:
        print(f"Slot {slot_idx} — {name}:")
        tile = _fetch_slot(category, result_index)
        if tile is None:
            print(f"    Using fallback colour {fallback_rgb}.")
            tile = Image.new("RGB", (_SLOT_W, _SLOT_H), fallback_rgb)
        atlas.paste(tile, (slot_idx * _SLOT_W, 0))

    atlas.save(FACADE_ATLAS_PNG)
    size_kb = FACADE_ATLAS_PNG.stat().st_size // 1024
    print(
        f"\nAtlas saved → {FACADE_ATLAS_PNG}  ({size_kb} KB)\n"
        "Slots: 0=plaster  1=brick_red  2=brick_beige  3=concrete  "
        "4=concrete_rough  5=limestone  6=stone  7=metal"
    )


if __name__ == "__main__":
    main()
