#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt

mkdir -p config data mcp-demo-workspace
if [[ ! -f config/provider.json ]]; then
  cp config/provider.example.json config/provider.json
  chmod 600 config/provider.json
fi
if [[ ! -f config/mcp.json ]]; then
  cp examples/mcp_config.example.json config/mcp.json
  chmod 600 config/mcp.json
fi

echo "Bootstrap complete."
echo "Memory:  .venv/bin/python -m memory.app"
echo "Runtime: .venv/bin/python -m server.app"
echo "Mobile:  cd mobile && flutter run"