#!/bin/sh
# Build the installable ORX Analytics.app (design §9 / task T012).
#
# Bundles a PINNED python-build-standalone runtime plus this repo's
# analytics code into the .app Resources, so a clean Mac needs no
# preinstalled Python/uv/Homebrew. The Swift app launches and manages
# the coordination engine through that bundled runtime.
#
# Usage: scripts/build_app.sh [dev|dist]
#   dev  — local development build: "ORX Analytics (Dev).app", bundle id
#          org.orxanalytics.macos.dev (separate defaults domain so dev
#          testing never clobbers real user settings), packed as a zip.
#   dist — distribution build: "ORX Analytics.app", bundle id
#          org.orxanalytics.macos, packed as a DMG.
#
# Requirements: macOS 13+ on Apple Silicon with the Swift 5.9 toolchain
# (swift build); the Python runtime is downloaded once into
# var/runtime-cache/ and its SHA256 is verified on EVERY use.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-dev}"
case "$MODE" in
  dev|dist) ;;
  *) echo "usage: $0 [dev|dist]" >&2; exit 2 ;;
esac

# ---- pinned standalone Python runtime (version + checksum frozen) --------
PBS_TAG="20250115"
PBS_PYTHON="cpython-3.12.8"
PBS_NAME="${PBS_PYTHON}+${PBS_TAG}-aarch64-apple-darwin-install_only"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_NAME}.tar.gz"
PBS_SHA256="e29003b69465c33692830032d9d237d84ea43a2e8461db9134641640fb49f040"
CACHE_DIR="$ROOT/var/runtime-cache"
TARBALL="$CACHE_DIR/$PBS_NAME.tar.gz"

# ---- app identity ---------------------------------------------------------
# The software version has a single source of truth:
# src/orxanalytics/__init__.py __version__ (CONTRIBUTING 发布检查).
VERSION=$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$ROOT/src/orxanalytics/__init__.py")
[ -n "$VERSION" ] || { echo "build_app.sh: cannot read __version__" >&2; exit 1; }
BUILD=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "nogit")

if [ "$MODE" = dist ]; then
  APP_NAME="ORX Analytics"
  BUNDLE_ID="org.orxanalytics.macos"
  FLAVOR="distribution"
else
  APP_NAME="ORX Analytics (Dev)"
  BUNDLE_ID="org.orxanalytics.macos.dev"
  FLAVOR="dev"
fi
DIST_DIR="$ROOT/var/dist"
STAGE="$DIST_DIR/$MODE"
APP="$STAGE/$APP_NAME.app"
ARCHIVE="$DIST_DIR/ORXAnalytics-${VERSION}-${MODE}-macos13-arm64.$([ "$MODE" = dist ] && echo dmg || echo zip)"

# ---- 1. pinned runtime: fetch if missing, verify checksum ALWAYS ---------
mkdir -p "$CACHE_DIR" "$STAGE"
if [ ! -f "$TARBALL" ]; then
  echo "build_app.sh: downloading pinned runtime $PBS_NAME ..."
  curl -fL --retry 3 -C - -o "$TARBALL" "$PBS_URL" \
    || { echo "build_app.sh: download failed; pre-seed $TARBALL to build offline" >&2; exit 1; }
fi
echo "$PBS_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null \
  || { echo "build_app.sh: SHA256 mismatch for $TARBALL" >&2; exit 1; }
echo "runtime: $PBS_NAME (sha256 verified)"

# ---- 2. Swift release binary (SwiftPM, Xcode-free) ------------------------
"$ROOT/scripts/build_macos_app.sh" release
BIN="$ROOT/apps/macos/.build/release/ORXAnalyticsApp"

ARCH=$(lipo -info "$BIN" 2>/dev/null || file "$BIN")
case "$ARCH" in
  *arm64*) ;;
  *) echo "build_app.sh: $BIN is not an arm64 build: $ARCH" >&2; exit 1 ;;
esac
MIN_OS=$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')
case "$MIN_OS" in
  13.*|1[4-9].*) ;;
  *) echo "build_app.sh: unexpected deployment target '$MIN_OS' (want >= 13.0)" >&2; exit 1 ;;
esac

# ---- 3. assemble the .app bundle ------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ORXAnalyticsApp"

# Python runtime: install_only tarball ships a relocatable python/ tree.
tar -xzf "$TARBALL" -C "$APP/Contents/Resources"
mv "$APP/Contents/Resources/python" "$APP/Contents/Resources/python.tmp"
mv "$APP/Contents/Resources/python.tmp" "$APP/Contents/Resources/python"

# Analytics code: stdlib-only package copied beside the runtime; the app
# runs `<bundled python> -m orxanalytics.engine` with PYTHONPATH here.
rm -rf "$APP/Contents/Resources/orxanalytics"
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' \
  "$ROOT/src/orxanalytics/" "$APP/Contents/Resources/orxanalytics/"
[ -f "$APP/Contents/Resources/orxanalytics/__init__.py" ] \
  || { echo "build_app.sh: analytics package missing from staging" >&2; exit 1; }
# The app's upgrade guard reads this to decide backup-before-migrate.
printf '%s\n' "$VERSION" > "$APP/Contents/Resources/orxanalytics-version.txt"

# Engine serve entry the app launches: the checked-in wrapper around
# the engine's public serve API (acquire + start_server + supervisor).
# `python -m orxanalytics.engine` currently never binds the socket —
# see the wrapper's docstring and docs/app-installation.md.
cp "$ROOT/apps/macos/Resources/orx_engine_serve.py" \
   "$APP/Contents/Resources/orx_engine_serve.py"

printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION+$FLAVOR+$BUILD</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>ORXAnalyticsApp</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Menu-bar-only app: no Dock icon, no main window (design §7). -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>ORX Analytics contributors</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<!-- Build flavor marker so the app itself can display it honestly. -->
	<key>ORXAnalyticsBuildFlavor</key>
	<string>$FLAVOR</string>
	<key>ORXAnalyticsBundledPython</key>
	<string>$PBS_NAME</string>
</dict>
</plist>
PLIST

# ---- 4. ad-hoc signature (Apple Silicon requires signed code) -------------
# NOTE: ad-hoc only — Developer ID signing + notarization are NOT done;
# this is a documented known limitation (docs/app-installation.md).
codesign --force --sign - --deep "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP" 2>/dev/null \
  || codesign --verify "$APP" 2>/dev/null \
  || { echo "build_app.sh: ad-hoc signature did not verify" >&2; exit 1; }
echo "signature: ad-hoc (not Developer ID signed, not notarized)"

# ---- 5. bounded self-test: the bundled runtime really runs the engine ----
# Fully synthetic: an empty ORX_DATA_DIR means discovery finds no projects,
# so the self-test never reads the developer's real sessions (CONTRIBUTING).
SELFTMP=$(mktemp -d "${TMPDIR:-/tmp}/orx-app-selftest.XXXXXX")
mkdir -p "$SELFTMP/empty-orx"
PYBIN="$APP/Contents/Resources/python/bin/python3"
ORX_DATA_DIR="$SELFTMP/empty-orx" "$PYBIN" \
  "$APP/Contents/Resources/orx_engine_serve.py" "$SELFTMP/data" \
  >"$SELFTMP/engine.out" 2>"$SELFTMP/engine.err" &
ENGPID=$!
SOCK="$SELFTMP/data/engine.sock"
OK=no
i=0
while [ "$i" -lt 30 ]; do
  if [ -S "$SOCK" ]; then OK=yes; break; fi
  kill -0 "$ENGPID" 2>/dev/null || break
  sleep 0.5
  i=$((i + 1))
done
if ! kill -0 "$ENGPID" 2>/dev/null; then
  wait "$ENGPID" || true
  echo "build_app.sh: bundled engine exited early:" >&2
  tail -5 "$SELFTMP/engine.err" >&2 || true
  rm -rf "$SELFTMP"
  exit 1
fi
kill "$ENGPID" 2>/dev/null || true
wait "$ENGPID" 2>/dev/null || true
rm -rf "$SELFTMP"
[ "$OK" = yes ] \
  || { echo "build_app.sh: bundled engine did not bind its socket in 15s" >&2; exit 1; }
echo "self-test: bundled engine served on its socket"

# ---- 6. archive (.app + install material) ---------------------------------
rm -f "$ARCHIVE"
if [ "$MODE" = dist ]; then
  IMGSTAGE="$STAGE/dmg-root"
  rm -rf "$IMGSTAGE"; mkdir -p "$IMGSTAGE"
  mv "$APP" "$IMGSTAGE/$APP_NAME.app"
  ln -s /Applications "$IMGSTAGE/Applications"
  hdiutil create -volname "ORX Analytics" -format UDZO \
    -srcfolder "$IMGSTAGE" "$ARCHIVE" -ov >/dev/null
  mv "$IMGSTAGE/$APP_NAME.app" "$APP"
  rm -rf "$IMGSTAGE"
else
  ditto -c -k --keepParent "$APP" "$ARCHIVE"
fi

echo
echo "build_app.sh: done ($FLAVOR)"
echo "  app:     $APP"
echo "  archive: $ARCHIVE"
echo "  version: $VERSION (python runtime $PBS_NAME, min macOS 13.0, arm64)"
