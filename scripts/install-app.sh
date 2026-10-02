#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
installed_app="$HOME/Applications/SuperUp.app"
if /usr/bin/pgrep -f "^$installed_app/Contents/MacOS/SuperUp$" >/dev/null 2>&1; then
  echo "Quit SuperUp from its menu before reinstalling." >&2
  exit 1
fi
"$project_dir/scripts/build-app.sh"
mkdir -p "$HOME/Applications"
ditto "$project_dir/build/SuperUp.app" "$installed_app"
open "$installed_app"
