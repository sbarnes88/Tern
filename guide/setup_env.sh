#!/usr/bin/env bash
set -euo pipefail

# Sets up a local Python virtual environment for building the Tern guide PDF.
# Installs: Pillow (PIL), reportlab, and playwright (+ Chromium browser).
#
# Usage:
#   cd guide
#   ./setup_env.sh
#   source .venv/bin/activate
#   python3 build_guide.py

cd "$(dirname "$0")"

PYTHON="${PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "Error: $PYTHON not found. Install Python 3 and retry." >&2
  exit 1
fi

echo "==> Creating virtual environment in ./ .venv ..."
"$PYTHON" -m venv .venv

# shellcheck disable=SC1091
source .venv/bin/activate

echo "==> Upgrading pip ..."
python -m pip install --upgrade pip

echo "==> Installing Python dependencies (Pillow, reportlab, playwright) ..."
python -m pip install Pillow reportlab playwright

echo "==> Installing Playwright Chromium browser (required for screenshots/validation) ..."
python -m playwright install chromium

echo
echo "Done."
echo "To build the guide:"
echo "  cd \"$(pwd)\""
echo "  source .venv/bin/activate"
echo "  python3 build_guide.py"
echo
echo "Output: Learn_Tern.pdf"
