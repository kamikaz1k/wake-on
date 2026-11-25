#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor Resources
archive=Vendor/sherpa-ios-1.13.4.tar.bz2
if [ ! -d Vendor/build-ios-no-tts ]; then
  curl --fail --location https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-ios-no-tts.tar.bz2 --output "$archive"
  printf '%s  %s\n' dcc5f1748144e88bdb17dfb7b9e5d06d194f478cdb6047adc133f9480c473b1a "$archive" | shasum -a 256 -c -
  tar -xjf "$archive" -C Vendor
fi
webrtc=Vendor/WebRTC-M153.xcframework.zip
if [ ! -d Vendor/WebRTC.xcframework ]; then
  # Same binary and checksum that stasel/WebRTC 153.0.0 publishes for Swift Package Manager.
  curl --fail --location https://github.com/stasel/WebRTC/releases/download/153.0.0/WebRTC-M153.xcframework.zip --output "$webrtc"
  printf '%s  %s\n' 3e3a8946f27510133e3feed04d05fa23505bbe366e977620503bfc7986c2b78f "$webrtc" | shasum -a 256 -c -
  unzip -q -o "$webrtc" -d Vendor
fi
model=../../models/sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20
if [ ! -d "$model" ]; then
  sh ../../scripts/setup-model.sh
fi
cp "$model/encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx" Resources/encoder.onnx
cp "$model/decoder-epoch-13-avg-2-chunk-8-left-64.onnx" Resources/decoder.onnx
cp "$model/joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx" Resources/joiner.onnx
cp "$model/tokens.txt" Resources/
# Pronouncing dictionary: the app builds its wake phrase ("Hey <name>") from it (WakePhrase.swift).
cp "$model/en.phone" Resources/lexicon.txt
fixture=${WAKE_FIXTURE:-../../recordings/positive/positive-001-quiet.wav}
if [ -f "$fixture" ]; then
  cp "$fixture" Resources/wake-fixture.wav
elif [ ! -f Resources/wake-fixture.wav ]; then
  # A valid silent resource keeps live-mic builds usable without private recordings.
  # The positive-fixture validation intentionally fails until WAKE_FIXTURE is supplied.
  python3 - <<'PY'
import wave
with wave.open('Resources/wake-fixture.wav','wb') as f:
    f.setparams((1,2,16000,0,'NONE','not compressed'))
    f.writeframes(b'\0\0'*16000)
PY
  echo 'No positive recording found. Live microphone works; set WAKE_FIXTURE for detector validation.'
fi
python3 scripts/generate-project.py
