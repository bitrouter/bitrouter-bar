#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-debug} "$repo_dir/scripts/package-app.sh" >/dev/null
open "$repo_dir/dist/BitRouter Bar.app"
