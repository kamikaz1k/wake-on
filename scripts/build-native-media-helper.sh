#!/bin/sh
set -eu

output_dir="native/macos-media-helper/bin"
mkdir -p "$output_dir"
swiftc \
  -O \
  -framework AVFoundation \
  native/macos-media-helper/Sources/WakeOnMediaHelper/main.swift \
  -o "$output_dir/wake-on-media-helper"
printf '%s\n' "Built $output_dir/wake-on-media-helper"
