#!/bin/bash
# Builds LDK Node 0.7.1 for iPhone (arm64) from source and assembles a local
# Swift package at ~/Developer/ldk-node-src/bindings/swift.
# Why: the v0.7.1 GitHub release has no prebuilt LDKNodeFFI.xcframework.zip yet,
# and 0.7.0 cannot talk to ACINQ's eclair after a reconnect (fixed in rust-lightning 0.2.2).
set -euo pipefail

SRC="$HOME/Developer/ldk-node-src"
SWIFT="$SRC/bindings/swift"
FW="$SWIFT/LDKNodeFFI.xcframework/ios-arm64/LDKNodeFFI.framework"

echo "== 1/6 source =="
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch v0.7.1 https://github.com/lightningdevkit/ldk-node.git "$SRC"
fi
cd "$SRC"

# BitKiss patch: VSS backup with seed-derived signature auth
# (adds Builder.buildWithVssStoreAndSigsAuth). Idempotent.
PATCH="$(cd "$(dirname "$0")" && pwd)/ldk-node-vss-sigs-auth.patch"
if ! grep -q build_with_vss_store_and_sigs_auth bindings/ldk_node.udl; then
  git apply "$PATCH"
fi

echo "== 2/6 rust toolchain =="
rustup target add aarch64-apple-ios

echo "== 3/6 compile for iPhone (this is the slow part, 10-30 min) =="
cargo build --profile release-smaller --features uniffi --target aarch64-apple-ios

echo "== 4/6 generate Swift bindings =="
cargo run --manifest-path bindings/uniffi-bindgen/Cargo.toml -- generate bindings/ldk_node.udl --language swift -o "$SWIFT"
sed -i '' '4s/^/import SystemConfiguration\n/' "$SWIFT/LDKNode.swift"
mkdir -p "$SWIFT/Sources/LDKNode"
mv "$SWIFT/LDKNode.swift" "$SWIFT/Sources/LDKNode/LDKNode.swift"

echo "== 5/6 assemble framework =="
cp "$SWIFT/LDKNodeFFI.h" "$FW/Headers/"
cp target/aarch64-apple-ios/release-smaller/libldk_node.a "$FW/LDKNodeFFI"
rm -f "$SWIFT/LDKNodeFFI.h" "$SWIFT/LDKNodeFFI.modulemap"

# Keep only the iPhone slice in the xcframework manifest (we did not build the others).
cat > "$SWIFT/LDKNodeFFI.xcframework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>LDKNodeFFI.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
			<key>MinimumOSVersion</key>
			<string>15.0</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
rm -rf "$SWIFT/LDKNodeFFI.xcframework/ios-arm64_x86_64-simulator" "$SWIFT/LDKNodeFFI.xcframework/macos-arm64_x86_64"

echo "== 6/6 done =="
ls -la "$FW/LDKNodeFFI"
echo
echo "Local package ready at: $SWIFT"
