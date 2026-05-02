#!/bin/sh
set -eu

if [ "${PLATFORM_NAME:-}" != "iphoneos" ]; then
  exit 0
fi

framework_binary="${BUILT_PRODUCTS_DIR:-}/DotLottiePlayer.framework/DotLottiePlayer"
if [ ! -f "$framework_binary" ]; then
  framework_binary="${TARGET_BUILD_DIR:-}/${FRAMEWORKS_FOLDER_PATH:-Frameworks}/DotLottiePlayer.framework/DotLottiePlayer"
fi

if [ ! -f "$framework_binary" ]; then
  echo "warning: DotLottiePlayer.framework binary was not found; skipping dSYM generation"
  exit 0
fi

dsym_name="DotLottiePlayer.framework.dSYM"
dsym_output="${DWARF_DSYM_FOLDER_PATH}/${dsym_name}"

mkdir -p "${DWARF_DSYM_FOLDER_PATH}"
xcrun dsymutil "$framework_binary" -o "$dsym_output"

if [ ! -d "$dsym_output" ]; then
  echo "error: failed to generate $dsym_name"
  exit 1
fi

xcrun dwarfdump --uuid "$dsym_output"
