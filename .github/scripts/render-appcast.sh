#!/usr/bin/env bash
# render-appcast.sh VERSION BUILD_NUMBER DMG_PATH ED_SIGNATURE RELEASE_NOTES_PATH
# Emits appcast.xml on stdout.
set -euo pipefail

VERSION="$1"
BUILD_NUMBER="$2"
DMG_PATH="$3"
ED_SIGNATURE="$4"
RELEASE_NOTES_PATH="$5"

DMG_NAME=$(basename "$DMG_PATH")
BYTE_LENGTH=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH")
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
NOTES=$(cat "$RELEASE_NOTES_PATH")
# CDATA cannot contain the sequence ']]>'. Split any occurrence across two
# CDATA sections so the XML remains well-formed even if a commit message
# literally contains ']]>'.
NOTES=${NOTES//]]>/]]]]><![CDATA[>}

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TheAll</title>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <description><![CDATA[${NOTES}]]></description>
      <enclosure
        url="https://github.com/AbadOrangeCat/TheALL/releases/download/v${VERSION}/${DMG_NAME}"
        sparkle:version="${BUILD_NUMBER}"
        sparkle:shortVersionString="${VERSION}"
        sparkle:edSignature="${ED_SIGNATURE}"
        length="${BYTE_LENGTH}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
