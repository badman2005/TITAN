#!/usr/bin/env bash
# Start the TITAN API using the venv and .env created by setup.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[ -d .venv ] && [ -f .env ] || { echo "Run ./setup.sh first"; exit 1; }
source .venv/bin/activate
set -a; source .env; set +a
exec uvicorn app.main:app --host "${HOST:-127.0.0.1}" --port "${PORT:-8000}" --reload
