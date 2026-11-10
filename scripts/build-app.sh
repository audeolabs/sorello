#!/usr/bin/env bash
# Assembles and signs the app bundle (ARCHITECTURE.md, section 10).
#   CHANNEL=dev|release   which identity from Config/identity.env (default dev)
#   SORELLO_MODEL_DIR     the pinned model bundle; required for CHANNEL=release
#   CODESIGN_IDENTITY     default "-" (ad hoc)
#   BUILD_DIR             default build
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source Config/identity.env

CHANNEL=${CHANNEL:-dev}
case "$CHANNEL" in
  dev) NAME=$DEV_NAME; BUNDLE_ID=$DEV_BUNDLE_ID ;;
  release) NAME=$RELEASE_NAME; BUNDLE_ID=$RELEASE_BUNDLE_ID ;;
  *) echo "build-app: CHANNEL must be dev or release" >&2; exit 64 ;;
esac
BUILD_DIR=${BUILD_DIR:-build}
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}
APP="$BUILD_DIR/$NAME.app"

if [ -z "${SORELLO_MODEL_DIR:-}" ] && [ "$CHANNEL" = release ]; then
  echo "build-app: a release build must include the model; set SORELLO_MODEL_DIR" >&2
  exit 1
fi

swift build -c release --arch arm64 --product Sorello
BIN=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Sorello" "$APP/Contents/MacOS/Sorello"

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
  # Only the files the manifest lists: the bundle directory may hold others the app never loads.
  /usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["files"]))' "$manifest" |
    while IFS= read -r file; do
      mkdir -p "$MODEL/$(dirname "$file")"
      cp "$SORELLO_MODEL_DIR/$file" "$MODEL/$file"
    done
  cp Resources/ModelNotices/* "$MODEL/"
else
  echo "build-app: built without the model; dictation cannot run in this bundle" >&2
fi

codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --entitlements Config/Sorello.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
