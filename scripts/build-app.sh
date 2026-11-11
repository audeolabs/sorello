#!/usr/bin/env bash
# Assembles and signs the app bundle (ARCHITECTURE.md, section 10).
#   CHANNEL               dev, nightly or release: which identity from Config/identity.conf (default dev)
#   ARCHS                 the executable's architectures, arm64 and/or x86_64, separated by spaces. Default: this
#                         Mac's for dev, both (universal) for nightly and release
#   BUILD_NUMBER          the bundle's build number, one to three whole numbers separated by dots. Default: BUILD
#                         in Config/identity.conf
#   SORELLO_MODEL_DIR     a local copy of a build the pin lists, for an app that carries the model and never
#                         downloads it. Without it the app downloads its model when it is set up
#   CODESIGN_IDENTITY     default "-" (ad hoc). A signature made with a certificate carries Apple's timestamp,
#                         which is fetched from Apple while signing
#   BUILD_DIR             default build
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source Config/identity.conf

CHANNEL=${CHANNEL:-dev}
case "$CHANNEL" in
  dev) NAME=$DEV_NAME; BUNDLE_ID=$DEV_BUNDLE_ID ;;
  nightly) NAME=$NIGHTLY_NAME; BUNDLE_ID=$NIGHTLY_BUNDLE_ID ;;
  release) NAME=$RELEASE_NAME; BUNDLE_ID=$RELEASE_BUNDLE_ID ;;
  *) echo "build-app: CHANNEL must be dev, nightly or release" >&2; exit 64 ;;
esac
# The build number a bundle may carry: the system compares it as up to three whole numbers.
BUILD=${BUILD_NUMBER:-$BUILD}
if ! [[ "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "build-app: BUILD_NUMBER must be one to three whole numbers separated by dots, not $BUILD" >&2
  exit 64
fi
# This Mac's architecture is its hardware's, which a shell running under Rosetta would misreport through uname.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then NATIVE=arm64; else NATIVE=x86_64; fi
if [ "$CHANNEL" = dev ]; then DEFAULT_ARCHS=$NATIVE; else DEFAULT_ARCHS="arm64 x86_64"; fi
# The words of ARCHS, however they are separated, each checked and then held between single spaces.
REQUESTED=" "
for arch in ${ARCHS:-$DEFAULT_ARCHS}; do
  case "$arch" in
    arm64|x86_64) REQUESTED="$REQUESTED$arch " ;;
    *) echo "build-app: ARCHS may name only arm64 and x86_64, not $arch" >&2; exit 64 ;;
  esac
done
# Each architecture once, in a fixed order, so the check at the end compares like with like.
WANTED=""
for arch in arm64 x86_64; do
  case "$REQUESTED" in *" $arch "*) WANTED="${WANTED:+$WANTED }$arch" ;; esac
done
[ -n "$WANTED" ] || { echo "build-app: ARCHS names no architecture" >&2; exit 64; }
BUILD_DIR=${BUILD_DIR:-build}
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}
APP="$BUILD_DIR/$NAME.app"

# The pin ships in every app: the app downloads the build it lists for the Mac it runs on. A pin that does not read
# here would not read in the app either.
/usr/bin/python3 - Models/model.lock.json <<'PY'
import json, re, sys

try:
    pin = json.load(open(sys.argv[1]))
    builds = pin["builds"]
    assert isinstance(pin["model"], str) and pin["source"].startswith("https://") and isinstance(builds, list)
    for build in builds:
        assert re.fullmatch(r"[0-9a-f]{64}", build["manifest_sha256"]) and isinstance(build["requires"], dict)
except (OSError, ValueError, KeyError, TypeError, AssertionError):
    sys.exit("build-app: Models/model.lock.json is not a pin the app can read")
PY

# One build per architecture, joined into one executable. Every --arch build writes to the same products directory,
# so each slice is copied out before the next one is built.
SLICES=$(mktemp -d "${TMPDIR:-/tmp}/sorello-slices.XXXXXX")
trap 'rm -rf "$SLICES"' EXIT
set --
for arch in $WANTED; do
  swift build -c release --arch "$arch" --product Sorello
  cp "$(swift build -c release --arch "$arch" --show-bin-path)/Sorello" "$SLICES/Sorello-$arch"
  set -- "$@" "$SLICES/Sorello-$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ $# -eq 1 ]; then
  cp "$1" "$APP/Contents/MacOS/Sorello"
else
  lipo -create -output "$APP/Contents/MacOS/Sorello" "$@"
fi

sed -e "s|__NAME__|$NAME|g" -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD|g" -e "s|__MINIMUM_SYSTEM__|$MINIMUM_SYSTEM|g" -e "s|__COPYRIGHT__|$COPYRIGHT|g" \
    Config/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp ThirdPartyNotices.md "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cp Models/model.lock.json "$APP/Contents/Resources/model.lock.json"
cp -R Resources/ModelNotices "$APP/Contents/Resources/ModelNotices"

if [ -n "${SORELLO_MODEL_DIR:-}" ]; then
  MODEL="$APP/Contents/Resources/Model"
  mkdir -p "$MODEL"
  # The copy must be a build the pin lists. Only the files its manifest lists are copied, each checked against its
  # hash first: the directory may hold others the app never loads, and an app must not carry a file it will refuse.
  /usr/bin/python3 - Models/model.lock.json "$SORELLO_MODEL_DIR" "$MODEL" <<'PY'
import hashlib, json, os, shutil, sys

pin, source, destination = sys.argv[1:4]

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()

manifest = os.path.join(source, "bundle.json")
if not os.path.isfile(manifest):
    sys.exit("build-app: no bundle.json in SORELLO_MODEL_DIR")
if sha256(manifest) not in [build["manifest_sha256"] for build in json.load(open(pin))["builds"]]:
    sys.exit("build-app: the model in SORELLO_MODEL_DIR is not a build Models/model.lock.json lists")
shutil.copyfile(manifest, os.path.join(destination, "bundle.json"))
for name, expected in json.load(open(manifest))["files"].items():
    parts = name.split("/")
    if os.path.isabs(name) or "\\" in name or any(part in ("", ".", "..") for part in parts):
        sys.exit(f"build-app: the model manifest names a path outside the bundle: {name}")
    path = os.path.join(source, name)
    if sha256(path) != expected:
        sys.exit(f"build-app: {name} does not match the model manifest")
    target = os.path.join(destination, name)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(path, target)
PY
else
  echo "build-app: the app downloads its model when it is set up" >&2
fi

# A certificate's signature carries Apple's timestamp: Apple notarizes nothing without one. An ad hoc signature has
# no certificate for a timestamp to vouch for.
if [ "$CODESIGN_IDENTITY" = "-" ]; then TIMESTAMP=--timestamp=none; else TIMESTAMP=--timestamp; fi
codesign --force --options runtime "$TIMESTAMP" --sign "$CODESIGN_IDENTITY" \
    --entitlements Config/Sorello.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# The executable that was signed holds exactly the architectures asked for, or there is no app. Sorted, the list
# reads in the same order as WANTED.
PACKAGED=$(lipo -archs "$APP/Contents/MacOS/Sorello" | tr ' ' '\n' | sort | paste -sd ' ' -)
if [ "$PACKAGED" != "$WANTED" ]; then
  echo "build-app: the executable holds $PACKAGED, not $WANTED" >&2
  rm -rf "$APP"
  exit 1
fi
echo "build-app: $NAME for $WANTED" >&2
echo "$APP"
