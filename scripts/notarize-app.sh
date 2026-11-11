#!/usr/bin/env bash
# Has Apple notarize an app signed with a Developer ID, staples the ticket to it, and writes the zip that is handed
# out (ARCHITECTURE.md, section 10). This uploads the app to Apple.
#   notarize-app.sh <app> <zip>
#   NOTARY_KEY_FILE     an App Store Connect API key, the .p8 file
#   NOTARY_KEY_ID       that key's ID
#   NOTARY_ISSUER_ID    the issuer ID of the team the key belongs to
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: notarize-app.sh <app> <zip>" >&2; exit 64; }
APP=$1
ZIP=$2
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
grep -q '^Authority=Developer ID Application: ' <<<"$SIGNATURE" || fail "the app is not signed with a Developer ID"
grep -q '^Timestamp=' <<<"$SIGNATURE" || fail "the app's signature carries no timestamp from Apple"
grep -q '^CodeDirectory .*flags=.*runtime' <<<"$SIGNATURE" || fail "the app is not signed with the hardened runtime"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sorello-notarize.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
KEY=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
ditto -c -k --keepParent "$APP" "$WORK/upload.zip"
# A refusal is reported below, with Apple's reasons; only a submission that could not be made stops here.
xcrun notarytool submit "$WORK/upload.zip" "${KEY[@]}" --wait --timeout 30m --output-format json \
    > "$WORK/result.json" || [ -s "$WORK/result.json" ] || fail "the submission could not be made"
read -r ID STATUS < <(/usr/bin/python3 - "$WORK/result.json" <<'PY'
import json, sys

try:
    result = json.load(open(sys.argv[1]))
    print(result.get("id") or "-", (result.get("status") or "unknown").replace(" ", "-"))
except (OSError, ValueError, AttributeError):
    print("- unreadable")
PY
)
if [ "$STATUS" != Accepted ]; then
  [ "$ID" = - ] || xcrun notarytool log "$ID" "${KEY[@]}" >&2 || true
  fail "Apple did not notarize the app: $STATUS"
fi

# The ticket travels with the app, so it opens on a Mac that cannot reach Apple. The app is then judged as the
# system judges one that was downloaded.
xcrun stapler staple "$APP" > /dev/null
xcrun stapler validate "$APP" > /dev/null || fail "the ticket is not stapled to the app"
ASSESSMENT=$(spctl --assess --type execute --verbose=2 "$APP" 2>&1) || fail "Gatekeeper refuses the app"
grep -q 'source=Notarized Developer ID' <<<"$ASSESSMENT" || fail "Gatekeeper does not see a notarized app"

rm -f "$ZIP"
mkdir -p "$(dirname "$ZIP")"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "notarize-app: notarized $(basename "$APP")" >&2
echo "$ZIP"
