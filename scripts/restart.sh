#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Stopping all Hermes services ==="
"$DIR/stop.sh"

echo ""
echo "=== Starting all Hermes services ==="
"$DIR/start.sh"
