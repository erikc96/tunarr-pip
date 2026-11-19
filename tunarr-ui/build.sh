#!/bin/bash
set -euo pipefail
mkdir -p tunarr-ui/build
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/tunarr-ui-swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
/usr/bin/swiftc -O tunarr-ui/main.swift -o tunarr-ui/build/tunarr-ui
