#!/usr/bin/env bash
# Has Apple notarize an app signed with a Developer ID, staples the ticket to it, and writes the disk image that is
# handed out: signed with the same Developer ID, notarized and stapled too (ARCHITECTURE.md, section 10). This
# uploads the app to Apple twice, on its own and inside the image.
#   notarize-app.sh <app> <dmg>
#   NOTARY_KEY_FILE     an App Store Connect API key, the .p8 file
#   NOTARY_KEY_ID       that key's ID
#   NOTARY_ISSUER_ID    the issuer ID of the team the key belongs to
# The image is signed with the certificate that signed the app, which must be in a keychain codesign can use.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: notarize-app.sh <app> <dmg>" >&2; exit 64; }
APP=$1
DMG=$2
fail() { echo "notarize-app: $*" >&2; exit 1; }
for name in NOTARY_KEY_FILE NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  [ -n "${!name:-}" ] || { echo "notarize-app: $name is not set" >&2; exit 64; }
done
[ -f "$NOTARY_KEY_FILE" ] || fail "NOTARY_KEY_FILE names no file"
[ -d "$APP" ] || fail "no app at $APP"

# Apple notarizes only what a Developer ID signed, with the hardened runtime and Apple's timestamp. An app without
# them is refused here, before minutes are spent learning the same from Apple.
codesign --verify --deep --strict "$APP" || fail "the app's signature does not verify"
SIGNATURE=$(codesign --display --verbose=4 "$APP" 2>&1)
IDENTITY=$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<<"$SIGNATURE" | head -1)
[ -n "$IDENTITY" ] || fail "the app is not signed with a Developer ID"
grep -q '^Timestamp=' <<<"$SIGNATURE" || fail "the app's signature carries no timestamp from Apple"
grep -q '^CodeDirectory .*flags=.*runtime' <<<"$SIGNATURE" || fail "the app is not signed with the hardened runtime"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sorello-notarize.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
KEY=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

# Uploads the file $2 to Apple and waits for the answer. $1 is what the file is, for a message: "app" or "image".
# A refusal is reported with Apple's reasons; a submission that could not be made stops at once.
notarize() {
  local what=$1 file=$2 result="$WORK/result-$1.json" id status
  xcrun notarytool submit "$file" "${KEY[@]}" --wait --timeout 30m --output-format json \
      > "$result" || [ -s "$result" ] || fail "the $what could not be submitted"
  read -r id status < <(/usr/bin/python3 - "$result" <<'PY'
import json, sys

try:
    result = json.load(open(sys.argv[1]))
    print(result.get("id") or "-", (result.get("status") or "unknown").replace(" ", "-"))
except (OSError, ValueError, AttributeError):
    print("- unreadable")
PY
  )
  if [ "$status" != Accepted ]; then
    [ "$id" = - ] || xcrun notarytool log "$id" "${KEY[@]}" >&2 || true
    fail "Apple did not notarize the $what: $status"
  fi
}

# The ticket travels with the app, so it opens on a Mac that cannot reach Apple. The app is then judged as the
# system judges one that was downloaded.
ditto -c -k --keepParent "$APP" "$WORK/upload.zip"
notarize app "$WORK/upload.zip"
xcrun stapler staple "$APP" > /dev/null
xcrun stapler validate "$APP" > /dev/null || fail "the ticket is not stapled to the app"
ASSESSMENT=$(spctl --assess --type execute --verbose=2 "$APP" 2>&1) || fail "Gatekeeper refuses the app"
grep -q 'source=Notarized Developer ID' <<<"$ASSESSMENT" || fail "Gatekeeper does not see a notarized app"

# The image holds the stapled app beside a way into Applications, so installing is one drag. It is made in the work
# directory and moved into place only once Gatekeeper accepts it: there is no image that was not notarized.
mkdir "$WORK/image"
ditto "$APP" "$WORK/image/$(basename "$APP")"
ln -s /Applications "$WORK/image/Applications"
IMAGE="$WORK/$(basename "$DMG")"
# The system can be slow to let go of a folder it has just been given; making the image is tried again then.
for attempt in 1 2 3; do
  if hdiutil create -volname "$(basename "$APP" .app)" -srcfolder "$WORK/image" -fs HFS+ -format UDZO -ov \
      "$IMAGE" > /dev/null; then
    break
  fi
  [ "$attempt" != 3 ] || fail "the disk image could not be made"
  sleep 5
done
codesign --sign "$IDENTITY" --timestamp "$IMAGE" || fail "the disk image could not be signed"
notarize image "$IMAGE"
xcrun stapler staple "$IMAGE" > /dev/null
xcrun stapler validate "$IMAGE" > /dev/null || fail "the ticket is not stapled to the disk image"
ASSESSMENT=$(spctl --assess --type open --context context:primary-signature --verbose=2 "$IMAGE" 2>&1) \
    || fail "Gatekeeper refuses the disk image"
grep -q 'source=Notarized Developer ID' <<<"$ASSESSMENT" || fail "Gatekeeper does not see a notarized disk image"

rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
mv "$IMAGE" "$DMG"
echo "notarize-app: notarized $(basename "$APP") and $(basename "$DMG")" >&2
echo "$DMG"
