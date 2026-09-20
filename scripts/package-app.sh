#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-release}
output_dir="$repo_dir/dist"
app_dir="$output_dir/BitRouter Bar.app"

swift build --package-path "$repo_dir" -c "$configuration"
bin_dir=$(swift build --package-path "$repo_dir" -c "$configuration" --show-bin-path)

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/BitRouterBar" "$app_dir/Contents/MacOS/BitRouterBar"
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"

echo "$app_dir"
