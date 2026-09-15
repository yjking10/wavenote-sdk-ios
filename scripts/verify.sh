#!/bin/bash
set -euo pipefail
demo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$demo_root"
mkdir -p build
logs="$(mktemp -d "$demo_root/build/verify.XXXXXX")"
run_check() {
    local name="$1"; shift
    if "$@" > "$logs/$name.log" 2>&1; then echo "PASS $name"; else tail -60 "$logs/$name.log"; echo "FAIL $name: $logs/$name.log" >&2; exit 1; fi
}
run_check binary-prepare bash scripts/prepare-sdk.sh "$@"
run_check flow-tests env DEMO_PLAYBACK_QA="$logs/playback.caf" swift test
run_check simulator-tests xcodebuild -project WaveNoteDemo.xcodeproj -scheme WaveNoteDemo \
    -destination "${WAVENOTE_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
    -derivedDataPath build/DerivedData -resultBundlePath "$logs/DemoTests.xcresult" CODE_SIGNING_ALLOWED=NO test
for config in Debug Release; do
    run_check "simulator-$config" xcodebuild -project WaveNoteDemo.xcodeproj -scheme WaveNoteDemo \
        -configuration "$config" -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
done
run_check device-release xcodebuild -project WaveNoteDemo.xcodeproj -scheme WaveNoteDemo \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
echo "Demo verification: $logs"
