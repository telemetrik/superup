#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
mkdir -p "$project_dir/.build/cache" "$project_dir/.build/clang-cache"
export XDG_CACHE_HOME="$project_dir/.build/cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-cache"
swift build -c release --disable-sandbox --scratch-path "$project_dir/.build" --cache-path "$project_dir/.build/cache"

app_dir="$project_dir/build/SuperUp.app"
mkdir -p "$app_dir/Contents/MacOS"
cp .build/release/SuperUp "$app_dir/Contents/MacOS/SuperUp"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
echo "$app_dir"
