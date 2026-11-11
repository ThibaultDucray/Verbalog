#!/bin/bash
# Installs the Python backend into .venv. Models are downloaded separately, from the app or `verbalog setup`.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v uv >/dev/null; then
    echo "uv est introuvable. Installez-le avec : brew install uv" >&2
    exit 1
fi
uv sync --all-extras
echo "Backend installé dans $(pwd)/.venv"
