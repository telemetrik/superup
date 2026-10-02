#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
mkdir -p "$project_dir/.build/cache" "$project_dir/.build/clang-cache"
export XDG_CACHE_HOME="$project_dir/.build/cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-cache"
swift run --disable-sandbox --scratch-path "$project_dir/.build" --cache-path "$project_dir/.build/cache" SuperUpChecks
