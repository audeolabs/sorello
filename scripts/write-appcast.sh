#!/usr/bin/env bash
# Writes the update feed for one build: an appcast that lists it, with the signature an installed app checks
# before it installs anything (ARCHITECTURE.md, section 6, "Updates", and section 10).
#   write-appcast.sh <app> <dmg> <url> <appcast>
#   UPDATE_KEY_FILE     the private half of the update key: its 32-byte seed in base64
# <app> is the app that is inside <dmg>, and <url> is where <dmg> will be downloaded from. The app's own
# Info.plist gives the version, the build, the minimum system and the public half of the key. No feed is written
# unless the image's signature verifies against that half.
set -euo pipefail
[ $# -eq 4 ] || { echo "usage: write-appcast.sh <app> <dmg> <url> <appcast>" >&2; exit 64; }
APP=$1
DMG=$2
URL=$3
APPCAST=$4
fail() { echo "write-appcast: $*" >&2; exit 1; }
[ -n "${UPDATE_KEY_FILE:-}" ] || { echo "write-appcast: UPDATE_KEY_FILE is not set" >&2; exit 64; }
[ -f "$UPDATE_KEY_FILE" ] || fail "UPDATE_KEY_FILE names no file"
[ -f "$DMG" ] || fail "no disk image at $DMG"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "no app at $APP"
case "$URL" in https://*) ;; *) fail "the download address must begin https://" ;; esac

value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2> /dev/null || true; }
NAME=$(value CFBundleName)
VERSION=$(value CFBundleShortVersionString)
BUILD=$(value CFBundleVersion)
MINIMUM=$(value LSMinimumSystemVersion)
PUBLIC=$(value SUPublicEDKey)
[ -n "$NAME" ] && [ -n "$VERSION" ] && [ -n "$BUILD" ] && [ -n "$MINIMUM" ] || fail "the app's Info.plist is incomplete"
[ -n "$PUBLIC" ] && [ -n "$(value SUFeedURL)" ] || fail "the app has no update feed, so it could not use one"
# What goes between the tags below is the app's name, numbers, the address and base64: nothing XML would misread.
case "$NAME$VERSION$BUILD$MINIMUM$URL" in *[\<\>\&\"\']*) fail "a value cannot be written into the feed as it is" ;; esac

SIGNATURE=$(xcrun swift "$(dirname "$0")/sign-update.swift" "$UPDATE_KEY_FILE" "$PUBLIC" "$DMG") \
    || fail "the disk image could not be signed with the update key"
LENGTH=$(stat -f %z "$DMG")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

mkdir -p "$(dirname "$APPCAST")"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$NAME</title>
    <item>
      <title>$VERSION ($BUILD)</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
XML
echo "write-appcast: $NAME $VERSION ($BUILD)" >&2
echo "$APPCAST"
