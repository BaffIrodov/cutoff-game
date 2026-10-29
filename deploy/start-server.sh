#!/usr/bin/env sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec ./godot --headless --main-pack cutoff.pck -- --server --port="${PORT:-9080}" "$@"
