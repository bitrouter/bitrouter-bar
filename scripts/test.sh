#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$repo_dir/.build"
swiftc \
  "$repo_dir/Sources/BitRouterBar/PanelModels.swift" \
  "$repo_dir/Sources/BitRouterBar/BroClient.swift" \
  "$repo_dir/Sources/BitRouterBar/PanelStore.swift" \
  "$repo_dir/Sources/BitRouterBar/MenuPresentation.swift" \
  "$repo_dir/Sources/BitRouterBar/NativeMenuController.swift" \
  "$repo_dir/Tests/NativeMenuTests.swift" \
  "$repo_dir/Tests/MenuPresentationTests.swift" \
  "$repo_dir/Tests/main.swift" \
  -o "$repo_dir/.build/BitRouterBarContractTests"
"$repo_dir/.build/BitRouterBarContractTests"
