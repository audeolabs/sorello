#!/usr/bin/env bash
# Assembles and signs the app bundle (ARCHITECTURE.md, section 10).
#   CHANNEL=dev|release   which identity from Config/identity.conf (default dev)
#   ARCHS                 the executable's architectures, arm64 and/or x86_64, separated by spaces. Default: this
#                         Mac's for dev, both (universal) for release
#   SORELLO_MODEL_DIR     the pinned model bundle; required for CHANNEL=release
#   CODESIGN_IDENTITY     default "-" (ad hoc)
#   BUILD_DIR             default build
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source Config/identity.conf

CHANNEL=${CHANNEL:-dev}
case "$CHANNEL" in
  dev) NAME=$DEV_NAME; BUNDLE_ID=$DEV_BUNDLE_ID ;;
  release) NAME=$RELEASE_NAME; BUNDLE_ID=$RELEASE_BUNDLE_ID ;;
  *) echo "build-app: CHANNEL must be dev or release" >&2; exit 64 ;;
esac
# This Mac's architecture is its hardware's, which a shell running under Rosetta would misreport through uname.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then NATIVE=arm64; else NATIVE=x86_64; fi
if [ "$CHANNEL" = release ]; then DEFAULT_ARCHS="arm64 x86_64"; else DEFAULT_ARCHS=$NATIVE; fi
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

if [ -z "${SORELLO_MODEL_DIR:-}" ] && [ "$CHANNEL" = release ]; then
  echo "build-app: a release build must include the model; set SORELLO_MODEL_DIR" >&2
  exit 1
fi

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

if [ -n "${SORELLO_MODEL_DIR:-}" ]; then
  manifest="$SORELLO_MODEL_DIR/bundle.json"
  [ -f "$manifest" ] || { echo "build-app: no bundle.json in SORELLO_MODEL_DIR" >&2; exit 1; }
  pinned=$(sed -n 's/.*"manifest_sha256": *"\([0-9a-f]*\)".*/\1/p' Models/model.lock.json)
  actual=$(shasum -a 256 "$manifest" | cut -d' ' -f1)
  if [ "$pinned" != "$actual" ]; then
    echo "build-app: the model in SORELLO_MODEL_DIR is not the one Models/model.lock.json pins" >&2
    exit 1
  fi
  MODEL="$APP/Contents/Resources/Model"
  mkdir -p "$MODEL"
  cp "$manifest" "$MODEL/"
  # Copy only the files the manifest lists, each checked against its hash first: the bundle directory may hold
  # others the app never loads, and a release must not ship a file the app will refuse.
  /usr/bin/python3 - "$manifest" "$SORELLO_MODEL_DIR" "$MODEL" <<'PY'
import hashlib, json, os, shutil, sys

manifest, source, destination = sys.argv[1:4]
for name, expected in json.load(open(manifest))["files"].items():
    if os.path.isabs(name) or ".." in name.split("/"):
        sys.exit(f"build-app: the model manifest names a path outside the bundle: {name}")
    path = os.path.join(source, name)
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        sys.exit(f"build-app: {name} does not match the model manifest")
    target = os.path.join(destination, name)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(path, target)
PY
  cp Resources/ModelNotices/* "$MODEL/"
else
  echo "build-app: built without the model; dictation cannot run in this bundle" >&2
fi

codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --entitlements Config/Sorello.entitlements "$APP"
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
