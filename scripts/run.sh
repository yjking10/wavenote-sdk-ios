#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
bash "$root/scripts/prepare-sdk.sh" "$@"
xcodebuild -project "$root/WaveNoteDemo.xcodeproj" -scheme WaveNoteDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath "$root/build/DerivedData" CODE_SIGNING_ALLOWED=NO build
open "$root/WaveNoteDemo.xcodeproj"
