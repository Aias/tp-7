#!/usr/bin/env bash
# Packages the companion as "TP-7 Companion.app" and installs it to
# /Applications. Signs with the first available Apple codesigning identity,
# falling back to ad-hoc (fine for personal use; TCC grants then re-prompt
# after each repackage, since ad-hoc signatures pin to the binary's hash).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="TP-7 Companion"
BUNDLE_ID="com.nicktrombley.tp7companion"
INSTALL_PATH="/Applications/$APP_NAME.app"

swift build -c release --package-path companion

STAGING="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$STAGING/Contents/MacOS"
cp companion/.build/release/companion "$STAGING/Contents/MacOS/companion"
cat > "$STAGING/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>companion</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Captures the TP-7 (or Mac) microphone for dictation and meeting recording.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Transcribes dictation on-device as you speak.</string>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$STAGING"
echo "Signed with: ${IDENTITY:-ad-hoc}"

# Point the installed app at a repo checkout for the ingest/transcription
# pipeline: the Conductor root checkout when packaging from a worktree,
# else this checkout. Existing config is left alone.
CONFIG="$HOME/.config/tp7companion/config.json"
if [ ! -f "$CONFIG" ]; then
	mkdir -p "$(dirname "$CONFIG")"
	printf '{\n\t"repoRoot": "%s"\n}\n' "${CONDUCTOR_ROOT_PATH:-$PWD}" > "$CONFIG"
	echo "Wrote $CONFIG"
fi

osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
rm -rf "$INSTALL_PATH"
ditto "$STAGING" "$INSTALL_PATH"
echo "Installed $INSTALL_PATH"
