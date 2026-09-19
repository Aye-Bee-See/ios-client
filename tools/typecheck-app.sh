#!/bin/sh
# Compiles the app target against the iOS Simulator SDK without Xcode's build system.
# Useful on a machine where the iOS platform component is not installed (xcodebuild then
# refuses every iOS destination, although the SDK itself ships inside Xcode), and as a
# quick check in CI. It type-checks everything; it does not produce an app.
set -e
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
SCRATCH=${SCRATCH:-ABCMailboxKit/.build/ios}
(cd ABCMailboxKit && swift build --triple arm64-apple-ios17.0-simulator --sdk "$SDK" --scratch-path "$(cd .. && pwd)/$SCRATCH" >/dev/null)
MODULES="$SCRATCH/arm64-apple-ios-simulator/debug/Modules"
# ABCCrypto imports libsodium's C module, so whoever imports ABCCrypto must be able to find its headers.
HEADERS=$(find "$SCRATCH/checkouts/swift-sodium/Clibsodium.xcframework" -path '*-simulator/Headers' -path '*ios-*' -type d | head -1)
find ABCMailbox -name '*.swift' -print0 | xargs -0 xcrun swiftc -typecheck \
  -sdk "$SDK" -target arm64-apple-ios17.0-simulator -swift-version 5 -D DEBUG \
  -I "$MODULES" -I "$HEADERS" \
  -parse-as-library
echo "The app target type-checks against $(basename "$SDK")."
