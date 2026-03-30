#!/usr/bin/env bash
# Create the Python venv and install all pipeline dependencies.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating venv ..."
    python3 -m venv "$VENV_DIR"
fi

echo "Installing dependencies ..."
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
"$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"

echo ""
echo "Done. Activate with:"
echo "  source tools/venv/bin/activate"
echo ""
echo "Then run the pipeline:"
echo "  python download_osm.py"
echo "  python extract_buildings.py"
echo "  python download_dem.py"
echo "  python process_dem.py"
echo "  python export_to_godot.py"
